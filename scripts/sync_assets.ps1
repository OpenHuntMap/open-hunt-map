$ErrorActionPreference = 'Stop'

# Only provinces.json is bundled. Overlays, policies and seasons are shipped as
# downloadable province packs so the binary stays small and map data can be
# refreshed without a store release. Build packs with tools/gis/build_packs.py.

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $RepoRoot 'data\provinces.json'
$Destination = Join-Path $RepoRoot 'app\assets\data'

if (-not (Test-Path $Source)) {
    throw "Source catalogue not found: $Source"
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Get-ChildItem -Path $Destination -Force |
    Where-Object { $_.Name -notin @('README.md', '.gitkeep') } |
    Remove-Item -Recurse -Force
Copy-Item -Path $Source -Destination $Destination -Force

Write-Host "Synced $Source -> $Destination"
