#!/usr/bin/env bash
# Optional: GeoJSON -> MBTiles (tippecanoe) -> PMTiles for MapLibre.
# Usage: ./build_pmtiles.sh <province> <layer>
# Example: ./build_pmtiles.sh on crown_land
#
# Prerequisites: tippecanoe, pmtiles (go-pmtiles) on PATH.
# See README.md for install links.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROVINCE="${1:?province code required (e.g. on)}"
LAYER="${2:?layer id required (e.g. crown_land)}"

GEOJSON="$REPO_ROOT/data/$PROVINCE/overlays/$LAYER.geojson"
MBTILES="$REPO_ROOT/data/$PROVINCE/overlays/$LAYER.mbtiles"
PMTILES="$REPO_ROOT/data/$PROVINCE/overlays/$LAYER.pmtiles"

if [[ ! -f "$GEOJSON" ]]; then
  echo "error: GeoJSON not found: $GEOJSON" >&2
  echo "Run: python build_overlays.py --province $PROVINCE" >&2
  exit 1
fi

command -v tippecanoe >/dev/null 2>&1 || {
  echo "error: tippecanoe not found on PATH" >&2
  exit 1
}
command -v pmtiles >/dev/null 2>&1 || {
  echo "error: pmtiles CLI not found on PATH" >&2
  exit 1
}

echo "Input:  $GEOJSON"
echo "Output: $PMTILES"

tippecanoe \
  -o "$MBTILES" \
  -zg \
  --drop-densest-as-needed \
  --extend-zooms-if-still-dropping \
  -l "$LAYER" \
  "$GEOJSON"

pmtiles convert "$MBTILES" "$PMTILES"

echo "Done. Update data/$PROVINCE/manifest.json to point at overlays/$LAYER.pmtiles (format: pmtiles) for release packs."
