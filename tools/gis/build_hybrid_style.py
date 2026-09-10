"""Generate the Hybrid basemap style: OpenFreeMap labels over provincial imagery.

Hybrid is satellite.json with a curated subset of the OpenFreeMap Liberty style
stacked on top, so roads, watercourses, boundaries and place names stay readable
against aerial photography.

The subset is taken from Liberty rather than hand-authored so that road
classification, label priority and zoom thresholds stay consistent with the
Streets basemap and can be refreshed when OpenFreeMap updates the style. Only
the text paint is overridden: Liberty is drawn for a pale background and its
dark grey labels disappear over imagery.

    python tools/gis/build_hybrid_style.py

Writes app/assets/styles/hybrid.json. Commit the result; it is a bundled asset.
"""

from __future__ import annotations

import json
from pathlib import Path

import requests

LIBERTY_URL = "https://tiles.openfreemap.org/styles/liberty"
REPO = Path(__file__).resolve().parents[2]
SATELLITE = REPO / "app" / "assets" / "styles" / "satellite.json"
OUTPUT = REPO / "app" / "assets" / "styles" / "hybrid.json"

# Ordered by Liberty's own layer order, which is what puts casings under fills
# and symbols above everything. Filtering that list preserves the ordering for
# free, so this is a membership test rather than a sequence.
KEEP = {
    # Watercourses. Small streams read poorly against tree cover in imagery and
    # they are a real navigation feature on foot.
    "waterway_river",
    "waterway_other",
    # Road casings, then the roads themselves. service_track carries forestry
    # and bush roads, and path_pedestrian carries trails; both matter more here
    # than they do in a street map.
    "road_service_track_casing",
    "road_minor_casing",
    "road_secondary_tertiary_casing",
    "road_trunk_primary_casing",
    "road_motorway_casing",
    "road_link_casing",
    "road_motorway_link_casing",
    "road_path_pedestrian",
    "road_service_track",
    "road_minor",
    "road_secondary_tertiary",
    "road_trunk_primary",
    "road_motorway",
    "road_link",
    "road_motorway_link",
    "bridge_service_track_casing",
    "bridge_street_casing",
    "bridge_secondary_tertiary_casing",
    "bridge_trunk_primary_casing",
    "bridge_motorway_casing",
    "bridge_link_casing",
    "bridge_motorway_link_casing",
    "bridge_service_track",
    "bridge_street",
    "bridge_secondary_tertiary",
    "bridge_trunk_primary",
    "bridge_motorway",
    "bridge_link",
    "bridge_motorway_link",
    "boundary_3",
    "boundary_2",
    # Labels.
    "waterway_line_label",
    "water_name_point_label",
    "water_name_line_label",
    "highway-name-path",
    "highway-name-minor",
    "highway-name-major",
    "highway-shield-non-us",
    "airport",
    "label_other",
    "label_village",
    "label_town",
    "label_state",
    "label_city",
    "label_city_capital",
}

# The shield glyph is a light plate with the number drawn on it, so recolouring
# its text to white would erase it.
KEEP_OWN_TEXT_PAINT = {"highway-shield-non-us"}

LABEL_PAINT = {
    "text-color": "#FFFFFF",
    "text-halo-color": "rgba(0, 0, 0, 0.85)",
    "text-halo-width": 1.6,
    "text-halo-blur": 0.4,
}


def fetch_liberty() -> dict:
    response = requests.get(LIBERTY_URL, timeout=60)
    response.raise_for_status()
    return response.json()


def restyle(layer: dict) -> dict:
    layer = json.loads(json.dumps(layer))
    if layer["type"] == "symbol" and layer["id"] not in KEEP_OWN_TEXT_PAINT:
        paint = layer.setdefault("paint", {})
        paint.update(LABEL_PAINT)
    return layer


def main() -> None:
    liberty = fetch_liberty()
    satellite = json.loads(SATELLITE.read_text(encoding="utf-8"))

    kept = [restyle(layer) for layer in liberty["layers"] if layer["id"] in KEEP]
    missing = KEEP - {layer["id"] for layer in liberty["layers"]}
    if missing:
        # Liberty renamed or dropped layers. Failing loudly beats shipping a
        # hybrid style that quietly lost its road network.
        raise SystemExit(f"Liberty no longer defines: {sorted(missing)}")

    style = {
        "version": 8,
        "name": "OpenWoodsMap Hybrid",
        "glyphs": liberty["glyphs"],
        "sprite": liberty["sprite"],
        "sources": {
            **satellite["sources"],
            "openmaptiles": liberty["sources"]["openmaptiles"],
        },
        "layers": satellite["layers"] + kept,
    }

    OUTPUT.write_text(
        json.dumps(style, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {OUTPUT.relative_to(REPO)} with {len(kept)} label layers")


if __name__ == "__main__":
    main()
