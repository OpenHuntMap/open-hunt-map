# Optional: GeoJSON -> MBTiles (tippecanoe) -> PMTiles for MapLibre.
# Usage: .\build_pmtiles.ps1 -Province on -Layer crown_land
#
# Prerequisites: tippecanoe, pmtiles (go-pmtiles) on PATH.
# See README.md for install links.

param(
    [Parameter(Mandatory = $true)]
    [string] $Province,

    [Parameter(Mandatory = $true)]
    [string] $Layer
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$GeoJson = Join-Path $RepoRoot "data\$Province\overlays\$Layer.geojson"
$MbTiles = Join-Path $RepoRoot "data\$Province\overlays\$Layer.mbtiles"
$PmTiles = Join-Path $RepoRoot "data\$Province\overlays\$Layer.pmtiles"

if (-not (Test-Path $GeoJson)) {
    Write-Error "GeoJSON not found: $GeoJson`nRun: python build_overlays.py --province $Province"
}

foreach ($cmd in @("tippecanoe", "pmtiles")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd not found on PATH. Install tippecanoe and go-pmtiles first."
    }
}

Write-Host "Input:  $GeoJson"
Write-Host "Output: $PmTiles"

& tippecanoe `
    -o $MbTiles `
    -zg `
    --drop-densest-as-needed `
    --extend-zooms-if-still-dropping `
    -l $Layer `
    $GeoJson

& pmtiles convert $MbTiles $PmTiles

Write-Host "Done. Update data/$Province/manifest.json to point at overlays/$Layer.pmtiles (format: pmtiles) for release packs."
