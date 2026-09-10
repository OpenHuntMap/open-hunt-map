#!/usr/bin/env python3
"""Fetch Ontario CLUPA Provincial polygons from LIO Open Data (OGL-Ontario).

Usage:
  python fetch_clupa_on.py --bbox -95.2,41.7,-74.3,56.9 --out ../../data/on/overlays/crown_land.geojson
  python fetch_clupa_on.py --province   # full Ontario envelope

Zero-infra: downloads once locally; app loads the static GeoJSON. No paid APIs.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from shapely.geometry import mapping, shape
    from shapely.validation import make_valid
except ImportError:
    print("Install deps: pip install -r requirements.txt", file=sys.stderr)
    raise

LAYER_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open06/MapServer/5/query"
)

# Approximate Ontario bbox (WGS84)
ON_BBOX = (-95.16, 41.68, -74.34, 56.86)
PAGE_SIZE = 1000


def _query(params: dict) -> dict:
    url = f"{LAYER_URL}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(f"Non-JSON response ({len(text)} chars): {text[:120]!r}")
    return json.loads(text)


def normalize(features: list[dict], simplify_tol: float) -> list[dict]:
    out: list[dict] = []
    for i, feature in enumerate(features, 1):
        props = feature.get("properties") or {}
        geom = feature.get("geometry")
        if not geom:
            continue
        try:
            geometry = shape(geom)
            if not geometry.is_valid:
                geometry = make_valid(geometry)
            if simplify_tol > 0:
                geometry = geometry.simplify(simplify_tol, preserve_topology=True)
            if geometry.is_empty or geometry.geom_type == "GeometryCollection":
                continue
        except Exception as exc:  # noqa: BLE001
            print(f"skip {i}: {exc}", file=sys.stderr)
            continue

        policy = props.get("POLICY_IDENT") or f"ON-{i}"
        name = props.get("NAME_ENG") or policy
        designation = (
            props.get("DESIGNATION_ENG")
            or props.get("CATEGORY_ENG")
            or "Crown land use area"
        )
        category = props.get("CATEGORY_ENG") or ""
        hunting: bool | str = "conditional"
        if "Park" in designation:
            hunting = False

        out.append(
            {
                "type": "Feature",
                "properties": {
                    "id": f"on-clupa-{policy}".replace(" ", "-"),
                    "name": name,
                    "designation": designation,
                    "category": category,
                    "policy_id": policy,
                    "hunting_allowed": hunting,
                    "summary": (
                        f"{designation}. Policy {policy}. "
                        "Ontario CLUPA Provincial (OGL-Ontario). "
                        "Verify current regulations before hunting."
                    ),
                    "source": "Ontario LIO Open Data — CLUPA Provincial",
                    "updated": "2026-09-06",
                    "province": "ON",
                },
                "geometry": mapping(geometry),
            }
        )
    return out


def fetch_bbox(bbox: tuple[float, float, float, float]) -> list[dict]:
    xmin, ymin, xmax, ymax = bbox
    features: list[dict] = []
    offset = 0
    while True:
        params = {
            "where": "1=1",
            "geometry": f"{xmin},{ymin},{xmax},{ymax}",
            "geometryType": "esriGeometryEnvelope",
            "inSR": "4326",
            "spatialRel": "esriSpatialRelIntersects",
            "outFields": "POLICY_IDENT,NAME_ENG,DESIGNATION_ENG,CATEGORY_ENG",
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson",
            "resultRecordCount": str(PAGE_SIZE),
            "resultOffset": str(offset),
        }
        try:
            page = _query(params)
        except Exception as exc:  # noqa: BLE001
            # Retry once as JSON (sometimes geojson body is empty/HTML on overload).
            params["f"] = "json"
            print(f"  geojson failed ({exc}); retrying as esri json...", flush=True)
            page = _esri_json_to_geojson(_query(params))
        if page.get("error"):
            raise RuntimeError(page["error"])
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  fetched {len(features)} features (offset={offset})", flush=True)
        if len(batch) < PAGE_SIZE:
            break
        offset += PAGE_SIZE
        if offset > 200_000:
            print("safety stop: too many features", file=sys.stderr)
            break
    return features


def _esri_json_to_geojson(payload: dict) -> dict:
    """Minimal converter for polygon rings from ArcGIS JSON."""
    out = []
    for feature in payload.get("features") or []:
        attrs = feature.get("attributes") or {}
        geom = feature.get("geometry") or {}
        rings = geom.get("rings")
        if not rings:
            continue
        out.append(
            {
                "type": "Feature",
                "properties": attrs,
                "geometry": {"type": "Polygon", "coordinates": rings},
            }
        )
    return {"type": "FeatureCollection", "features": out}


def fetch_tiled(
    bbox: tuple[float, float, float, float],
    rows: int = 6,
    cols: int = 6,
) -> list[dict]:
    xmin, ymin, xmax, ymax = bbox
    width = (xmax - xmin) / cols
    height = (ymax - ymin) / rows
    seen: set[str] = set()
    features: list[dict] = []
    for row in range(rows):
        for col in range(cols):
            tile = (
                xmin + col * width,
                ymin + row * height,
                xmin + (col + 1) * width,
                ymin + (row + 1) * height,
            )
            print(f"Tile r{row}c{col}: {tile}", flush=True)
            for feature in fetch_bbox(tile):
                props = feature.get("properties") or {}
                key = str(props.get("POLICY_IDENT") or props.get("OBJECTID") or id(feature))
                if key in seen:
                    continue
                seen.add(key)
                features.append(feature)
    return features


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bbox",
        help="xmin,ymin,xmax,ymax WGS84",
        default=None,
    )
    parser.add_argument(
        "--province",
        action="store_true",
        help="Use full Ontario envelope (tiled queries)",
    )
    parser.add_argument(
        "--tiles",
        type=int,
        default=6,
        help="Grid size for provincial tiled fetch (NxN)",
    )
    parser.add_argument(
        "--simplify",
        type=float,
        default=0.001,
        help="Shapely simplify tolerance in degrees (0=off)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2]
        / "data"
        / "on"
        / "overlays"
        / "crown_land.geojson",
    )
    args = parser.parse_args()

    if args.bbox:
        parts = [float(x) for x in args.bbox.split(",")]
        if len(parts) != 4:
            parser.error("--bbox needs xmin,ymin,xmax,ymax")
        bbox = (parts[0], parts[1], parts[2], parts[3])
        coverage = f"bbox {bbox}"
        raw = fetch_bbox(bbox)
    else:
        bbox = ON_BBOX
        coverage = f"Ontario province envelope ({args.tiles}x{args.tiles} tiles)"
        print(f"Fetching CLUPA for {coverage} ...")
        raw = fetch_tiled(bbox, rows=args.tiles, cols=args.tiles)

    print(f"Normalizing {len(raw)} features (simplify={args.simplify}) ...")
    features = normalize(raw, args.simplify)
    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "crown_land",
            "feature_count": len(features),
            "coverage": coverage,
            "license": "OGL-Ontario",
            "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
            "source": "LIO Open06 MapServer layer 5 (CLUPA Provincial)",
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    size_mb = args.out.stat().st_size / (1024 * 1024)
    print(f"Wrote {len(features)} features -> {args.out} ({size_mb:.2f} MiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
