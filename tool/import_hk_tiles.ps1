param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$targetPath = Join-Path $ProjectRoot 'assets\map_tiles\hong_kong'
$projectPath = (Resolve-Path -LiteralPath $ProjectRoot).Path
$resolvedTarget = [System.IO.Path]::GetFullPath($targetPath)

if (-not $resolvedTarget.StartsWith($projectPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Tile target is outside the project: $resolvedTarget"
}

$tiles = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter '*.png'
if ($tiles.Count -eq 0) {
    throw 'No PNG tiles were found. Expected {z}\{x}\{y}.png.'
}

$invalid = $tiles | Where-Object {
    $relative = $_.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
    $relative -notmatch '^(10|11|12|13|14|15|16)[\\/]\d+[\\/]\d+\.png$'
} | Select-Object -First 1
if ($null -ne $invalid) {
    throw "Invalid tile path: $($invalid.FullName). Expected zoom 10-16 in {z}\{x}\{y}.png format."
}

New-Item -ItemType Directory -Path $resolvedTarget -Force | Out-Null
Copy-Item -Path (Join-Path $sourcePath '*') -Destination $resolvedTarget -Recurse -Force
Write-Host "Imported $($tiles.Count) offline tiles into $resolvedTarget"
Write-Host 'Run flutter pub get, then rebuild the app so Flutter bundles the assets.'
