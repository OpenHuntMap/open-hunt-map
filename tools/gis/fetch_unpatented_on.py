#!/usr/bin/env python3
"""Fetch Ontario Crown Land – MNR Unpatented Land (OGL-Ontario).

Positive tenure layer: parcels still owned/managed by MNR that were never
patented (plus forfeitures/depatents). Intersected with CLUPA designations
in filter_huntable_crown.py.

Writes tools/gis/_tmp_patent/unpatented_crown.geojson (gitignored).
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

OUT_DIR = Path(__file__).resolve().parent / "_tmp_patent"
OUT = OUT_DIR / "unpatented_crown.geojson"
LAYER_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open08/MapServer/34/query"
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
            "outFields": (
                "OGF_ID,OBJECTID,SURVEY_LOCATION_IDENT,AREA_IN_HA,LOCATION_DESCR"
            ),
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
        print(f"  unpatented offset={offset} total={len(features)}", flush=True)
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
                        "ogf_id": props.get("OGF_ID"),
                        "survey_location": props.get("SURVEY_LOCATION_IDENT"),
                        "location_descr": props.get("LOCATION_DESCR"),
                        "area_ha": props.get("AREA_IN_HA"),
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
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--page-size", type=int, default=2000)
    parser.add_argument(
        "--simplify",
        type=float,
        default=0.0004,
        help="Degrees (~40m); server + local",
    )
    args = parser.parse_args()

    print("Fetching Crown Land – MNR Unpatented Land …", flush=True)
    raw = fetch_all(page_size=args.page_size, simplify_tol=args.simplify)
    features = simplify_features(raw, tol=args.simplify)
    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "layer": "crown_land_mnr_unpatented",
            "feature_count": len(features),
            "source": LAYER_URL,
            "license": "OGL-Ontario",
            "simplify_degrees": args.simplify,
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
