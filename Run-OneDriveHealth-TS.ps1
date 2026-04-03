[CmdletBinding()]
param(
    # Optional: allow one remediation restart cycle in TS mode.
    [switch]$EnableAutoRemediation,
    # Optional: allow OneDrive login UI launch when OneDrive is stopped.
    [switch]$LaunchUiIfStopped,
    # Optional aggressive mode: permit restart of running OneDrive on sync/sign-in failures.
    [switch]$RestartRunningClient
)

$ErrorActionPreference = 'SilentlyContinue'

$mainScript = Join-Path $PSScriptRoot 'OneDrive-Health-Synthetic-Deploy.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    [Console]::Out.WriteLine('2')
    exit 0
}

try {
    $args = @('-TsSafeMode')

    if ($EnableAutoRemediation) {
        $args += '-EnableAutoRemediation'
    }
    if ($LaunchUiIfStopped) {
        $args += '-NoUiLaunchWhenStopped:$false'
    }
    if ($RestartRunningClient) {
        $args += '-RestartRunningClient'
    }

    & $mainScript @args
} catch {
    [Console]::Out.WriteLine('2')
    exit 0
}
