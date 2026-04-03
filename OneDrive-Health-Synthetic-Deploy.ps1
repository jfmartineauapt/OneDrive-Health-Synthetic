# OneDrive synthetic health monitor (deploy version)
# Numeric output only:
# 0 = OK
# 1 = OneDrive not running
# 2 = Sync failure / not signed in
# 3 = No user logged in

[CmdletBinding()]
param(
    [switch]$EnableAutoRemediation,
    [switch]$RestartRunningClient,
    [switch]$TsSafeMode,
    [switch]$NoUiLaunchWhenStopped,
    [ValidateRange(1, 300)]
    [int]$StartupJitterMinSeconds = 1,
    [ValidateRange(1, 300)]
    [int]$StartupJitterMaxSeconds = 5,
    [ValidateRange(20, 300)]
    [int]$SyncWaitMinSeconds = 20,
    [ValidateRange(20, 300)]
    [int]$SyncWaitMaxSeconds = 60,
    # If enabled, require log-churn evidence to return OK.
    [switch]$RequireLogChurnEvidence,
    [switch]$DisableStatusFileWrite,
    [string]$StatusRootPath = 'C:\AT\logs'
)

$ErrorActionPreference = 'SilentlyContinue'

$CodeOk = 0
$CodeOneDriveNotRunning = 1
$CodeSyncFailure = 2
$CodeNoUser = 3

$script:RestartAttempted = $false
$script:LogScanPerRootLimitNormal = 40
$script:LogScanPerRootLimitRetry = 120
$script:LogCutoffMinutes = 60

if ($TsSafeMode) {
    if (-not $PSBoundParameters.ContainsKey('NoUiLaunchWhenStopped')) {
        $NoUiLaunchWhenStopped = $true
    }
    if (-not $PSBoundParameters.ContainsKey('StartupJitterMinSeconds')) {
        $StartupJitterMinSeconds = 5
    }
    if (-not $PSBoundParameters.ContainsKey('StartupJitterMaxSeconds')) {
        $StartupJitterMaxSeconds = 25
    }
    if (-not $PSBoundParameters.ContainsKey('SyncWaitMinSeconds')) {
        $SyncWaitMinSeconds = 20
    }
    if (-not $PSBoundParameters.ContainsKey('SyncWaitMaxSeconds')) {
        $SyncWaitMaxSeconds = 45
    }

    $script:LogScanPerRootLimitNormal = 20
    $script:LogScanPerRootLimitRetry = 60
}

if ($StartupJitterMaxSeconds -lt $StartupJitterMinSeconds) {
    $StartupJitterMaxSeconds = $StartupJitterMinSeconds
}
if ($SyncWaitMaxSeconds -lt $SyncWaitMinSeconds) {
    $SyncWaitMaxSeconds = $SyncWaitMinSeconds
}

function Get-RandomInRange {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Minimum,
        [Parameter(Mandatory = $true)]
        [int]$Maximum
    )

    if ($Maximum -le $Minimum) {
        return $Minimum
    }

    return (Get-Random -Minimum $Minimum -Maximum ($Maximum + 1))
}

function Ensure-DirectoryExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        return (Test-Path -LiteralPath $Path -PathType Container)
    } catch {
        return $false
    }
}

function Get-SafeUserKey {
    $domain = $env:USERDOMAIN
    $user = $env:USERNAME

    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = 'UNKNOWNDOMAIN' }
    if ([string]::IsNullOrWhiteSpace($user)) { $user = 'UNKNOWNUSER' }

    $raw = '{0}_{1}' -f $domain, $user
    return ($raw -replace '[^A-Za-z0-9._-]', '_')
}

function Write-StatusArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    if ($DisableStatusFileWrite) {
        return
    }

    try {
        if ([string]::IsNullOrWhiteSpace($StatusRootPath)) {
            return
        }

        $statusRoot = $StatusRootPath.TrimEnd('\')
        $statusDir = Join-Path $statusRoot 'status'
        if (-not (Ensure-DirectoryExists -Path $statusRoot)) { return }
        if (-not (Ensure-DirectoryExists -Path $statusDir)) { return }

        $codeText = [string]$Code
        $globalStatusFile = Join-Path $statusRoot 'status.txt'
        $userStatusFile = Join-Path $statusDir ((Get-SafeUserKey) + '.txt')

        Set-Content -LiteralPath $globalStatusFile -Value $codeText -Encoding ASCII -NoNewline -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $userStatusFile -Value $codeText -Encoding ASCII -NoNewline -Force -ErrorAction SilentlyContinue
    } catch {
    }
}

function Emit-Code {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    try { Write-StatusArtifacts -Code $Code } catch {}

    try {
        [Console]::Out.WriteLine([string]$Code)
    } catch {
    }

    exit 0
}

function Normalize-PathForCompare {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return ($Path.Trim().TrimEnd('\', '/').ToLowerInvariant())
}

function Test-InteractiveUserContext {
    try {
        if (-not [Environment]::UserInteractive) {
            return $false
        }

        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $identity) {
            return $false
        }

        if ($identity.IsSystem) {
            return $false
        }

        if ($identity.Name -match '^(NT AUTHORITY\\SYSTEM|NT AUTHORITY\\LOCAL SERVICE|NT AUTHORITY\\NETWORK SERVICE)$') {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($env:USERNAME) -or [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

function Test-OneDriveRunningInCurrentSession {
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $proc = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId } |
            Select-Object -First 1

        return [bool]$proc
    } catch {
        return $false
    }
}

function Get-OneDriveExePath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Start-OneDriveLoginUi {
    try {
        $exePath = Get-OneDriveExePath
        if ([string]::IsNullOrWhiteSpace($exePath)) {
            return $false
        }

        Start-Process -FilePath $exePath -ErrorAction SilentlyContinue | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Restart-OneDriveOnce {
    if ($script:RestartAttempted) {
        return $false
    }

    $script:RestartAttempted = $true

    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $exePath = Get-OneDriveExePath
        if ([string]::IsNullOrWhiteSpace($exePath)) {
            return $false
        }

        $procs = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId }
        if (-not $procs) {
            return $false
        }

        try {
            Start-Process -FilePath $exePath -ArgumentList '/shutdown' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 3
        } catch {
        }

        foreach ($proc in $procs) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }

        Start-Sleep -Seconds 3
        Start-Process -FilePath $exePath -ArgumentList '/background' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 8

        return (Test-OneDriveRunningInCurrentSession)
    } catch {
        return $false
    }
}

function Get-BusinessAccounts {
    try {
        $accountsRoot = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        if (-not (Test-Path -LiteralPath $accountsRoot -PathType Container)) {
            return @()
        }

        $accounts = @()
        $keys = Get-ChildItem -LiteralPath $accountsRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'Business*' }

        foreach ($key in $keys) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }

            $accounts += [pscustomobject]@{
                KeyName    = [string]$key.PSChildName
                UserEmail  = [string]$props.UserEmail
                UserFolder = [string]$props.UserFolder
            }
        }

        return $accounts
    } catch {
        return @()
    }
}

function Get-ActiveBusinessAccount {
    try {
        $accounts = Get-BusinessAccounts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.UserEmail) }
        if (-not $accounts) {
            return $null
        }

        $envOneDriveNorm = Normalize-PathForCompare -Path $env:OneDrive
        if (-not [string]::IsNullOrWhiteSpace($envOneDriveNorm)) {
            $match = $accounts | Where-Object {
                (Normalize-PathForCompare -Path ([string]$_.UserFolder)) -eq $envOneDriveNorm
            } | Select-Object -First 1
            if ($match) { return $match }
        }

        return ($accounts | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Test-OneDriveBusinessSignedIn {
    try {
        $active = Get-ActiveBusinessAccount
        if ($active -and -not [string]::IsNullOrWhiteSpace([string]$active.UserEmail)) {
            return $true
        }

        if (-not [string]::IsNullOrWhiteSpace($env:OneDrive) -and (Test-Path -LiteralPath $env:OneDrive -PathType Container)) {
            return $true
        }

        return $false
    } catch {
        return $false
    }
}

function Get-OneDriveBusinessLogRoots {
    try {
        $logsBase = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\logs'
        if (-not (Test-Path -LiteralPath $logsBase -PathType Container)) {
            return @()
        }

        $roots = @()
        $active = Get-ActiveBusinessAccount
        if ($active -and -not [string]::IsNullOrWhiteSpace([string]$active.KeyName)) {
            $roots += (Join-Path $logsBase ([string]$active.KeyName))
        }

        $roots += (Join-Path $logsBase 'Business1')

        $allBusinessDirs = Get-ChildItem -LiteralPath $logsBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Business*' } |
            Select-Object -ExpandProperty FullName

        if ($allBusinessDirs) {
            $roots += $allBusinessDirs
        }

        return $roots |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container) } |
            Sort-Object -Unique
    } catch {
        return @()
    }
}

function Get-LatestOneDriveLogWriteUtc {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$CutoffUtc,
        [Parameter(Mandatory = $true)]
        [int]$PerRootFileLimit
    )

    try {
        $roots = Get-OneDriveBusinessLogRoots
        if (-not $roots) {
            return [datetime]::MinValue
        }

        $latest = [datetime]::MinValue
        foreach ($root in $roots) {
            $files = Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $CutoffUtc } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First $PerRootFileLimit

            foreach ($file in $files) {
                if ($file.LastWriteTimeUtc -gt $latest) {
                    $latest = $file.LastWriteTimeUtc
                }
            }
        }

        return $latest
    } catch {
        return [datetime]::MinValue
    }
}

function Get-EasternIsoTimestamp {
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
        return [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $tz).ToString('o')
    } catch {
        return [datetimeoffset]::UtcNow.ToString('o')
    }
}

function Invoke-SyntheticTransaction {
    try {
        $oneDriveRoot = [string]$env:OneDrive
        if ([string]::IsNullOrWhiteSpace($oneDriveRoot) -or -not (Test-Path -LiteralPath $oneDriveRoot -PathType Container)) {
            return $false
        }

        $monitorFolder = Join-Path $oneDriveRoot '_monitor'
        if (-not (Ensure-DirectoryExists -Path $monitorFolder)) {
            return $false
        }

        $healthFile = Join-Path $monitorFolder 'health.txt'
        $preLogMarkerUtc = Get-LatestOneDriveLogWriteUtc -CutoffUtc ([datetime]::UtcNow.AddMinutes(-1 * $script:LogCutoffMinutes)) -PerRootFileLimit $script:LogScanPerRootLimitNormal

        $writeStartUtc = [datetime]::UtcNow
        $timestampValue = Get-EasternIsoTimestamp
        Set-Content -LiteralPath $healthFile -Value $timestampValue -Encoding UTF8 -Force -ErrorAction SilentlyContinue

        $healthInfo = Get-Item -LiteralPath $healthFile -ErrorAction SilentlyContinue
        if (-not $healthInfo) {
            return $false
        }
        if ($healthInfo.LastWriteTimeUtc -lt $writeStartUtc.AddSeconds(-2)) {
            return $false
        }

        $waitSeconds = Get-RandomInRange -Minimum $SyncWaitMinSeconds -Maximum $SyncWaitMaxSeconds
        Start-Sleep -Seconds $waitSeconds

        if (-not (Test-OneDriveRunningInCurrentSession)) {
            return $false
        }

        $postLogMarkerUtc = Get-LatestOneDriveLogWriteUtc -CutoffUtc $writeStartUtc.AddMinutes(-2) -PerRootFileLimit $script:LogScanPerRootLimitNormal
        if ($postLogMarkerUtc -gt $preLogMarkerUtc -and $postLogMarkerUtc -ge $writeStartUtc.AddSeconds(-1)) {
            return $true
        }

        Start-Sleep -Seconds 8
        if (-not (Test-OneDriveRunningInCurrentSession)) {
            return $false
        }

        $postRetryUtc = Get-LatestOneDriveLogWriteUtc -CutoffUtc $writeStartUtc.AddMinutes(-2) -PerRootFileLimit $script:LogScanPerRootLimitRetry
        if ($postRetryUtc -gt $preLogMarkerUtc -and $postRetryUtc -ge $writeStartUtc.AddSeconds(-1)) {
            return $true
        }

        if ($RequireLogChurnEvidence) {
            return $false
        }

        # Functional fallback for endpoints where OneDrive logs are too opaque/noisy:
        # accept success when core health signals are good.
        $healthInfoFinal = Get-Item -LiteralPath $healthFile -ErrorAction SilentlyContinue
        if ($healthInfoFinal -and
            $healthInfoFinal.LastWriteTimeUtc -ge $writeStartUtc.AddSeconds(-2) -and
            (Test-OneDriveRunningInCurrentSession) -and
            (Test-OneDriveBusinessSignedIn)) {
            return $true
        }

        return $false
    } catch {
        return $false
    }
}

try {
    Start-Sleep -Seconds (Get-RandomInRange -Minimum $StartupJitterMinSeconds -Maximum $StartupJitterMaxSeconds)
} catch {
}

if (-not (Test-InteractiveUserContext)) {
    Emit-Code -Code $CodeNoUser
}

if (-not (Test-OneDriveRunningInCurrentSession)) {
    if (-not $NoUiLaunchWhenStopped) {
        [void](Start-OneDriveLoginUi)
    }
    Emit-Code -Code $CodeOneDriveNotRunning
}

if (-not (Test-OneDriveBusinessSignedIn)) {
    if ($EnableAutoRemediation -and $RestartRunningClient) {
        [void](Restart-OneDriveOnce)
    }

    if (-not (Test-OneDriveBusinessSignedIn)) {
        Emit-Code -Code $CodeSyncFailure
    }
}

if (Invoke-SyntheticTransaction) {
    Emit-Code -Code $CodeOk
}

if ($EnableAutoRemediation -and $RestartRunningClient) {
    if (Restart-OneDriveOnce) {
        if (Invoke-SyntheticTransaction) {
            Emit-Code -Code $CodeOk
        }
    }
}

Emit-Code -Code $CodeSyncFailure
