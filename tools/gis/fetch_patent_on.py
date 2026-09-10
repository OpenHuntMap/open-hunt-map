#!/usr/bin/env python3
"""Fetch Ontario Patent Land External (OGL-Ontario) for tenure subtract.

Source: LIO Open08 MapServer layer 35 — lands sold/transferred by the Crown
and not managed under MNRF mandate (private, municipal, federal, etc.).

Writes a simplified cache under tools/gis/_tmp_patent/ (gitignored). Used by
filter_huntable_crown.py; not shipped in the app pack.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent / "_tmp_patent"
OUT = OUT_DIR / "patent_land.geojson"
LAYER_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open08/MapServer/35/query"
)


def query(params: dict) -> dict:
    full = f"{LAYER_URL}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(full, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(text[:200])
    return json.loads(text)


def fetch_all(*, page_size: int, simplify_tol: float) -> list[dict]:
    features: list[dict] = []
    offset = 0
    while True:
        params = {
            "where": "1=1",
            "outFields": "OBJECTID,TITLE_HOLDER_TYPE,CROWN_RESERVATION_TYPE",
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson",
            "resultRecordCount": str(page_size),
            "resultOffset": str(offset),
            "maxAllowableOffset": str(simplify_tol),
        }
        page = query(params)
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  patent offset={offset} total={len(features)}", flush=True)
        if len(batch) < page_size:
            break
        offset += page_size
    return features


def simplify_features(raw: list[dict], tol: float) -> list[dict]:
    out: list[dict] = []
    skipped = 0
    for feature in raw:
        geom = feature.get("geometry")
        if not geom:
            skipped += 1
            continue
        try:
            g = shape(geom)
            if not g.is_valid:
                g = make_valid(g)
            if tol > 0:
                g = g.simplify(tol, preserve_topology=True)
            if g.is_empty or g.geom_type == "GeometryCollection":
                skipped += 1
                continue
            props = feature.get("properties") or {}
            out.append(
                {
                    "type": "Feature",
                    "properties": {
                        "title_holder": props.get("TITLE_HOLDER_TYPE"),
                        "crown_reservation": props.get("CROWN_RESERVATION_TYPE"),
                    },
                    "geometry": mapping(g),
                }
            )
        except Exception:  # noqa: BLE001
            skipped += 1
    print(f"Simplified kept={len(out)} skipped={skipped}", flush=True)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=OUT,
        help="Output GeoJSON path",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=2000,
        help="ArcGIS page size (max 2000)",
    )
    parser.add_argument(
        "--simplify",
        type=float,
        default=0.0004,
        help="Degrees; ~40m at mid-latitudes (server + local)",
    )
    args = parser.parse_args()

    print("Fetching Patent Land External …", flush=True)
    raw = fetch_all(page_size=args.page_size, simplify_tol=args.simplify)
    features = simplify_features(raw, tol=args.simplify)
    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "layer": "patent_land_external",
            "feature_count": len(features),
            "source": LAYER_URL,
            "license": "OGL-Ontario",
            "simplify_degrees": args.simplify,
            "note": (
                "Lands sold/transferred by the Crown (not MNRF-managed). "
                "Used only to difference huntable Crown overlays."
            ),
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(
        f"Wrote {len(features)} features -> {args.out} "
        f"({args.out.stat().st_size / 1e6:.1f} MB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
