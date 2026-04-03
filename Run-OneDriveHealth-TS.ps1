[CmdletBinding()]
param(
    # Optional: allow one remediation restart cycle in TS mode.
    [switch]$EnableAutoRemediation,
    # Optional: allow OneDrive login UI launch when OneDrive is stopped.
    [switch]$LaunchUiIfStopped
)

$ErrorActionPreference = 'SilentlyContinue'

$mainScript = Join-Path $PSScriptRoot 'OneDrive-Health-Synthetic.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    [Console]::Out.WriteLine('2')
    exit 0
}

try {
    if ($EnableAutoRemediation) {
        if ($LaunchUiIfStopped) {
            & $mainScript -TsSafeMode -EnableAutoRemediation -NoUiLaunchWhenStopped:$false
        } else {
            & $mainScript -TsSafeMode -EnableAutoRemediation
        }
    } else {
        if ($LaunchUiIfStopped) {
            & $mainScript -TsSafeMode -NoUiLaunchWhenStopped:$false
        } else {
            & $mainScript -TsSafeMode
        }
    }
} catch {
    [Console]::Out.WriteLine('2')
    exit 0
}
