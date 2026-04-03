# OneDrive synthetic health monitor for Zabbix (user context)
# Returns numeric codes only:
# 0 = OK (sync working)
# 1 = OneDrive not running
# 2 = Sync failure
# 3 = No user logged in / non-user context

[CmdletBinding()]
param(
    # Keep remediation opt-in to avoid disturbing end users.
    [switch]$EnableAutoRemediation,
    # TS/FSLogix tuning profile: lowers per-run IO and disables UI launch if OneDrive is stopped.
    [switch]$TsSafeMode,
    # If set, do not launch OneDrive UI when OneDrive is stopped.
    [switch]$NoUiLaunchWhenStopped,
    # Startup jitter window (seconds) to spread endpoint execution.
    [ValidateRange(1, 300)]
    [int]$StartupJitterMinSeconds = 1,
    [ValidateRange(1, 300)]
    [int]$StartupJitterMaxSeconds = 5,
    # Synthetic sync observation wait window (seconds).
    [ValidateRange(20, 300)]
    [int]$SyncWaitMinSeconds = 20,
    [ValidateRange(20, 300)]
    [int]$SyncWaitMaxSeconds = 60
)

$ErrorActionPreference = 'SilentlyContinue'

$CodeOk = 0
$CodeOneDriveNotRunning = 1
$CodeSyncFailure = 2
$CodeNoUser = 3
$script:RestartAttempted = $false
$script:LogCandidateFileLimit = 25
$script:LogTailLineCount = 400
$script:LogTailByteLimit = 262144
$script:LogSearchRecencyMinutes = 2
$script:TsFastLogScan = $false

# Apply TS-safe defaults only when the caller did not provide explicit overrides.
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

    # Reduce disk pressure for dense TS hosts.
    $script:LogCandidateFileLimit = 12
    $script:LogTailLineCount = 250
    $script:LogTailByteLimit = 131072
    $script:LogSearchRecencyMinutes = 3
    $script:TsFastLogScan = $true
}

if ($StartupJitterMaxSeconds -lt $StartupJitterMinSeconds) {
    $StartupJitterMaxSeconds = $StartupJitterMinSeconds
}
if ($SyncWaitMaxSeconds -lt $SyncWaitMinSeconds) {
    $SyncWaitMaxSeconds = $SyncWaitMinSeconds
}

function Emit-Code {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    try {
        [Console]::Out.WriteLine([string]$Code)
    } catch {
        # Swallow all output errors to keep script safe.
    }

    # Exit 0 intentionally so Zabbix item remains supported.
    exit 0
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

    # Get-Random uses an exclusive upper bound.
    return (Get-Random -Minimum $Minimum -Maximum ($Maximum + 1))
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

        $name = $identity.Name
        if ($name -match '^(NT AUTHORITY\\SYSTEM|NT AUTHORITY\\LOCAL SERVICE|NT AUTHORITY\\NETWORK SERVICE)$') {
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

function Test-OneDriveBusinessSignedIn {
    try {
        # Business1 is the OneDrive for Business account profile.
        $accountKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
        if (-not (Test-Path -LiteralPath $accountKey)) {
            return $false
        }

        $account = Get-ItemProperty -LiteralPath $accountKey -ErrorAction SilentlyContinue
        if (-not $account) {
            return $false
        }

        $userEmail = [string]$account.UserEmail
        $userFolder = [string]$account.UserFolder

        if ([string]::IsNullOrWhiteSpace($userEmail)) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($userFolder)) {
            return $false
        }

        return $true
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

        # Start without /background so OneDrive can present sign-in/setup UI.
        Start-Process -FilePath $exePath -ErrorAction SilentlyContinue | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Restart-OneDriveOnce {
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $exePath = Get-OneDriveExePath
        if ([string]::IsNullOrWhiteSpace($exePath)) {
            return $false
        }

        $procs = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId }

        # Never cold-start OneDrive from a stopped state in silent monitoring mode.
        if (-not $procs) {
            return $false
        }

        # Prefer graceful shutdown to reduce user-visible behavior.
        try {
            Start-Process -FilePath $exePath -ArgumentList '/shutdown' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 3
        } catch {
        }

        foreach ($proc in $procs) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }

        Start-Sleep -Seconds 3

        # /background avoids opening OneDrive UI during health remediation.
        Start-Process -FilePath $exePath -ArgumentList '/background' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null

        Start-Sleep -Seconds 8

        return (Test-OneDriveRunningInCurrentSession)
    } catch {
        return $false
    }
}

function Invoke-OneDriveRemediationRestart {
    if ($script:RestartAttempted) {
        return $false
    }

    $script:RestartAttempted = $true
    return (Restart-OneDriveOnce)
}

function Test-NeedleInFileTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Needle
    )

    # First try text tail (cheap and effective for text logs).
    try {
        $tailLines = Get-Content -LiteralPath $Path -Tail $script:LogTailLineCount -ErrorAction Stop
        if ($tailLines) {
            foreach ($line in $tailLines) {
                if ($line -match '(?i)health\.txt' -and $line -match '(?i)_monitor') {
                    return $true
                }
                if ($line -match '(?i)health\.txt') {
                    return $true
                }
            }
        }
    } catch {
    }

    # Fallback for binary-ish logs: inspect only recent bytes for the marker string.
    try {
        $maxBytes = $script:LogTailByteLimit
        $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($fileInfo.Length -le 0) {
            return $false
        }

        $bytesToRead = [int][Math]::Min([double]$maxBytes, [double]$fileInfo.Length)
        $buffer = New-Object byte[] $bytesToRead

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $startOffset = [Math]::Max(0, $fileInfo.Length - $bytesToRead)
            $stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            [void]$stream.Read($buffer, 0, $bytesToRead)
        } finally {
            $stream.Dispose()
        }

        $needleCmp = [System.StringComparison]::OrdinalIgnoreCase
        $utf8 = [System.Text.Encoding]::UTF8.GetString($buffer)
        if ($utf8.IndexOf($Needle, $needleCmp) -ge 0) {
            return $true
        }

        $unicode = [System.Text.Encoding]::Unicode.GetString($buffer)
        if ($unicode.IndexOf($Needle, $needleCmp) -ge 0) {
            return $true
        }
    } catch {
    }

    return $false
}

function Get-RecentBusinessLogCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogsRoot,
        [Parameter(Mandatory = $true)]
        [datetime]$CutoffUtc
    )

    try {
        if ($script:TsFastLogScan) {
            # TS mode: first inspect top-level files to reduce deep profile traversal.
            $topLevel = Get-ChildItem -LiteralPath $LogsRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $CutoffUtc } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First $script:LogCandidateFileLimit

            if ($topLevel) {
                return $topLevel
            }
        }

        $recursive = Get-ChildItem -LiteralPath $LogsRoot -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -ge $CutoffUtc } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First $script:LogCandidateFileLimit

        return $recursive
    } catch {
        return @()
    }
}

function Test-RecentSyncEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$WriteTimeUtc
    )

    try {
        $logsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\logs\Business1'
        if (-not (Test-Path -LiteralPath $logsRoot -PathType Container)) {
            return $false
        }

        # Tight recency filter to reduce stale-match false positives.
        $cutoffUtc = $WriteTimeUtc.AddMinutes(-1 * $script:LogSearchRecencyMinutes)
        $candidateFiles = Get-RecentBusinessLogCandidates -LogsRoot $logsRoot -CutoffUtc $cutoffUtc

        if (-not $candidateFiles) {
            return $false
        }

        foreach ($file in $candidateFiles) {
            if (Test-NeedleInFileTail -Path $file.FullName -Needle 'health.txt') {
                return $true
            }
        }
    } catch {
    }

    return $false
}

function Invoke-SyntheticTransaction {
    try {
        $oneDriveRoot = $env:OneDrive
        if ([string]::IsNullOrWhiteSpace($oneDriveRoot) -or -not (Test-Path -LiteralPath $oneDriveRoot -PathType Container)) {
            return $false
        }

        $monitorFolder = Join-Path $oneDriveRoot '_monitor'
        if (-not (Test-Path -LiteralPath $monitorFolder -PathType Container)) {
            New-Item -Path $monitorFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $healthFile = Join-Path $monitorFolder 'health.txt'
        $timestampValue = $null
        try {
            $easternTz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
            $timestampValue = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $easternTz).ToString('o')
        } catch {
            # Fallback should never be needed on Windows, but keep writes resilient.
            $timestampValue = [datetimeoffset]::UtcNow.ToString('o')
        }
        $writeStartUtc = [datetime]::UtcNow
        Set-Content -LiteralPath $healthFile -Value $timestampValue -Encoding UTF8 -Force -ErrorAction SilentlyContinue

        # Ensure the single synthetic file was actually updated before checking logs.
        $healthFileInfo = Get-Item -LiteralPath $healthFile -ErrorAction SilentlyContinue
        if (-not $healthFileInfo) {
            return $false
        }

        if ($healthFileInfo.LastWriteTimeUtc -lt $writeStartUtc.AddSeconds(-2)) {
            return $false
        }

        $writeTimeUtc = [datetime]::UtcNow

        # Required randomized wait to let OneDrive produce sync telemetry.
        $syncWaitSeconds = Get-RandomInRange -Minimum $SyncWaitMinSeconds -Maximum $SyncWaitMaxSeconds
        Start-Sleep -Seconds $syncWaitSeconds

        return (Test-RecentSyncEvidence -WriteTimeUtc $writeTimeUtc)
    } catch {
        return $false
    }
}

# Small startup jitter to avoid fleet-wide synchronized access bursts.
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

$isSignedIn = Test-OneDriveBusinessSignedIn
if (-not $isSignedIn) {
    if ($EnableAutoRemediation) {
        [void](Invoke-OneDriveRemediationRestart)
    }

    if (-not (Test-OneDriveBusinessSignedIn)) {
        Emit-Code -Code $CodeSyncFailure
    }
}

$syncOk = Invoke-SyntheticTransaction
if ($syncOk) {
    Emit-Code -Code $CodeOk
}

if ($EnableAutoRemediation) {
    $restartOk = $false
    # Guard against launching OneDrive for not-signed-in profiles (can open UI/Explorer).
    if (Test-OneDriveBusinessSignedIn) {
        $restartOk = Invoke-OneDriveRemediationRestart
    }
    if ($restartOk) {
        $syncOkAfterRestart = Invoke-SyntheticTransaction
        if ($syncOkAfterRestart) {
            Emit-Code -Code $CodeOk
        }
    }
}

Emit-Code -Code $CodeSyncFailure
