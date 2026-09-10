#!/usr/bin/env sh
set -eu

# Only provinces.json is bundled. Overlays, policies and seasons are shipped as
# downloadable province packs so the binary stays small and map data can be
# refreshed without a store release. Build packs with tools/gis/build_packs.py.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
SOURCE="$REPO_ROOT/data/provinces.json"
DESTINATION="$REPO_ROOT/app/assets/data"

if [ ! -f "$SOURCE" ]; then
  echo "Source catalogue not found: $SOURCE" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
find "$DESTINATION" -mindepth 1 -maxdepth 1 \
  ! -name README.md ! -name .gitkeep -exec rm -rf {} +
cp "$SOURCE" "$DESTINATION"/

echo "Synced $SOURCE -> $DESTINATION"
