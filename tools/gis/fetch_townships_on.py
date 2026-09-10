#!/usr/bin/env python3
"""Fetch Ontario geographic townships (OGL-Ontario) from LIO."""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/townships.geojson"
LAYER = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open06/MapServer/1/query"
)


def query(params: dict) -> dict:
    url = f"{LAYER}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    return json.loads(text)


def fetch_all(*, simplify: float) -> list[dict]:
    features: list[dict] = []
    offset = 0
    page_size = 1000
    while True:
        page = query(
            {
                "where": "1=1",
                "outFields": "OFFICIAL_NAME,OGF_ID",
                "returnGeometry": "true",
                "outSR": "4326",
                "f": "geojson",
                "resultRecordCount": str(page_size),
                "resultOffset": str(offset),
                "maxAllowableOffset": str(simplify),
            }
        )
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  townships offset={offset} total={len(features)}", flush=True)
        if len(batch) < page_size:
            break
        offset += page_size
    return features


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--simplify", type=float, default=0.001)
    args = parser.parse_args()

    raw = fetch_all(simplify=args.simplify)
    out = []
    for i, feature in enumerate(raw, 1):
        props = feature.get("properties") or {}
        name = (
            props.get("OFFICIAL_NAME")
            or props.get("NAME_ENGLISH")
            or props.get("NAME_FRENCH")
            or f"Township {i}"
        )
        geom = feature.get("geometry")
        if not geom:
            continue
        try:
            g = shape(geom)
            if not g.is_valid:
                g = make_valid(g)
            if args.simplify > 0:
                g = g.simplify(args.simplify, preserve_topology=True)
            if g.is_empty or g.geom_type == "GeometryCollection":
                continue
            out.append(
                {
                    "type": "Feature",
                    "properties": {
                        "id": f"on-twp-{props.get('OGF_ID') or i}",
                        "name": str(name).strip(),
                        "type": "geographic_township",
                        "province": "ON",
                        "source": "Ontario LIO — Geographic Township Improved",
                    },
                    "geometry": mapping(g),
                }
            )
        except Exception as exc:  # noqa: BLE001
            print(f"skip {name}: {exc}")

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "layer": "townships",
            "feature_count": len(out),
            "coverage": "Ontario geographic townships (survey)",
            "license": "OGL-Ontario",
            "source": LAYER,
            "note": "Survey townships — not municipal bylaw jurisdiction.",
        },
        "features": out,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(out)} -> {args.out} ({args.out.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
