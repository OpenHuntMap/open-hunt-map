#!/usr/bin/env python3
"""Fetch Ontario Hydro Network waterbodies, for build-time use only.

Nothing from this file ships. Ontario's tenure record covers the beds of lakes
and rivers, correctly — a lake bed is unpatented Crown land — but the card a user
gets in the middle of open water was word for word the card they get on dry
ground. Comparing our card against iHunter's over Round Lake and Burns Lake
showed us claiming hunting is permitted on ground that is under water while they
either said nothing or retreated to "contact MNR".

Dropping those parcels is not the fix: it would manufacture an exclusion the
province never made, and waterfowl hunting over Crown water is legal. So the
parcels stay and build_crown_on.py flags the ones that are water, which needs a
hydrography layer we do not otherwise carry.

The 1:500,000 generalisation is used rather than the full Ontario Hydro Network.
Full resolution is 1.4 million polygons; this is 55,000, and the question being
asked of it — is this parcel a lake bed rather than dry ground — is a question
about whole lakes, not shorelines. The measured fraction is reported so the
threshold in build_crown_on.py can be set against real numbers.

Writes tools/gis/_tmp_hydro/ohn_waterbody.geojson, which is gitignored.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

GIS = Path(__file__).resolve().parent
TMP = GIS / "_tmp_hydro"
OUT = TMP / "ohn_waterbody.geojson"

URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open02/MapServer/12/query"
)
SOURCE = "Ontario LIO — OHN 500K Waterbody"
PAGE = 1000
# ~50 m. The source is already generalised to 1:500,000, so this only trims
# vertices the generalisation left behind.
SIMPLIFY = 0.0005


def query(params: dict) -> dict:
    full = f"{URL}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(full, headers={"User-Agent": "OpenWoodsMap/1.0"})
    with urllib.request.urlopen(request, timeout=600) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(text[:200])
    return json.loads(text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download even if the cached extract looks complete",
    )
    args = parser.parse_args()

    TMP.mkdir(parents=True, exist_ok=True)
    if OUT.is_file() and not args.force:
        cached = json.loads(OUT.read_text(encoding="utf-8"))
        count = len(cached.get("features") or [])
        if count > 50000:
            print(f"Using cached {OUT} ({count} waterbodies)")
            return 0
        print(f"Cached {OUT} holds only {count} waterbodies; re-fetching")

    features: list[dict] = []
    offset = 0
    while True:
        page = query(
            {
                "where": "1=1",
                "outFields": "OBJECTID",
                "returnGeometry": "true",
                "outSR": "4326",
                "f": "geojson",
                "resultRecordCount": str(PAGE),
                "resultOffset": str(offset),
                "maxAllowableOffset": str(SIMPLIFY),
            }
        )
        batch = page.get("features") or []
        # Attributes are not needed; only the footprint is. Dropping them keeps
        # the build-time extract to something that fits comfortably in memory.
        features.extend({"geometry": f.get("geometry")} for f in batch)
        if offset % 10000 == 0 or len(batch) < PAGE:
            print(f"  offset={offset} total={len(features)}", flush=True)
        if len(batch) < PAGE:
            break
        offset += PAGE

    features = [f for f in features if f["geometry"]]
    if len(features) < 50000:
        print(
            f"Only {len(features)} waterbodies fetched, expected about 55,000. "
            "Refusing to cache a partial extract, because a missing lake reads "
            "as dry ground.",
            file=sys.stderr,
        )
        return 1

    OUT.write_text(
        json.dumps(
            {
                "type": "FeatureCollection",
                "metadata": {"source": SOURCE, "crs": "EPSG:4326"},
                "features": features,
            },
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
    print(
        f"Wrote {len(features)} waterbodies -> {OUT} "
        f"({OUT.stat().st_size / 1e6:.1f} MB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
