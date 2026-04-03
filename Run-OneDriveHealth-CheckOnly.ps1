[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$mainScript = Join-Path $PSScriptRoot 'OneDrive-Health-Synthetic.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    [Console]::Out.WriteLine('2')
    exit 0
}

try {
    & $mainScript
} catch {
    [Console]::Out.WriteLine('2')
    exit 0
}
