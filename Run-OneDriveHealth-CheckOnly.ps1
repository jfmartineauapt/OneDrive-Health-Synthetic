[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$mainScript = Join-Path $PSScriptRoot 'OneDrive-Health-Synthetic-Deploy.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    [Console]::Out.WriteLine('2')
    exit 0
}

try {
    # Check-only mode must never launch OneDrive UI.
    & $mainScript -NoUiLaunchWhenStopped
} catch {
    [Console]::Out.WriteLine('2')
    exit 0
}
