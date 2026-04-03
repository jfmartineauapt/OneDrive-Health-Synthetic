[CmdletBinding()]
param(
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
    if ($RestartRunningClient) {
        & $mainScript -EnableAutoRemediation -RestartRunningClient
    } else {
        & $mainScript -EnableAutoRemediation
    }
} catch {
    [Console]::Out.WriteLine('2')
    exit 0
}
