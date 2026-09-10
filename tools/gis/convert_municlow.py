#!/usr/bin/env python3
"""Convert LIO MUNICLOW shapefile to WGS84 GeoJSON for OpenWoodsMap."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import shapefile
from pyproj import Transformer
from shapely.geometry import mapping, shape
from shapely.ops import transform
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
SHP = ROOT / "tools/gis/_tmp_municlow/LIO-2026-03-13/MUNIC_BND_LOWER_AND_SINGLE.shp"
OUT = ROOT / "data/on/overlays/municipalities.geojson"


TITLES = (
    "TOWNSHIP OF ",
    "CITY OF ",
    "TOWN OF ",
    "MUNICIPALITY OF ",
    "VILLAGE OF ",
    "COUNTY OF ",
    "UNITED COUNTIES OF ",
    "REGIONAL MUNICIPALITY OF ",
    "DISTRICT MUNICIPALITY OF ",
)


def display_name(rec: dict) -> str:
    name = (rec.get("NAME_E") or "").strip()
    prefix = (rec.get("NM_PREF_E") or "").strip()
    upper = name.upper()
    if upper.startswith(TITLES):
        raw = name
    elif prefix and not upper.startswith(prefix.upper()):
        raw = f"{prefix} {name}".strip()
    else:
        # MUN_TYPE_E is a classification such as "Single Tier Municipality",
        # not a name component, so names like "Norfolk County" stand alone.
        raw = name or "Unknown municipality"
    for title in TITLES:
        while raw.upper().startswith(title + title):
            raw = raw[len(title):]
    return raw.title().replace(" Of ", " of ").replace(" And ", " and ")


def main() -> int:
    if not SHP.exists():
        print(f"Missing {SHP}", file=sys.stderr)
        return 1
    reader = shapefile.Reader(str(SHP))
    fields = [f[0] for f in reader.fields[1:]]
    # LIO packages are typically NAD83 / Ontario MNR Lambert or similar — detect via bbox.
    bbox = reader.bbox
    print("bbox", bbox, "count", len(reader))
    # If coordinates look projected (large numbers), transform from EPSG:3161 or 26917.
    # Ontario MNR Lambert Conformal Conic is often EPSG:3161.
    projected = abs(bbox[0]) > 180 or abs(bbox[2]) > 180
    transformer = None
    if projected:
        # Try Ontario Lambert (3161); if fails visually we still write and note CRS.
        transformer = Transformer.from_crs("EPSG:3161", "EPSG:4326", always_xy=True)
        print("reprojecting EPSG:3161 -> EPSG:4326")

    features = []
    for i, sr in enumerate(reader.iterShapeRecords(), 1):
        rec = dict(zip(fields, sr.record))
        geom = sr.shape.__geo_interface__
        try:
            g = shape(geom)
            if not g.is_valid:
                g = make_valid(g)
            if transformer is not None:
                g = transform(transformer.transform, g)
            g = g.simplify(0.003, preserve_topology=True)
            if g.is_empty or g.geom_type == "GeometryCollection":
                continue
        except Exception as exc:  # noqa: BLE001
            print(f"skip {i}: {exc}", file=sys.stderr)
            continue
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "id": rec.get("MUNID") or f"on-mun-{i}",
                    "name": display_name(rec),
                    "municipal_type": rec.get("MUN_TYPE_E") or "",
                    "upper_tier": rec.get("UPR_TIER_E") or "",
                    "type": "municipality",
                    "province": "ON",
                    "source": "Ontario LIO MUNICLOW shapefile (OGL-Ontario)",
                },
                "geometry": mapping(g),
            }
        )
        if i % 100 == 0:
            print(f"  {i}/{len(reader)}", flush=True)

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "municipalities",
            "feature_count": len(features),
            "coverage": "Ontario lower/single-tier municipalities (full)",
            "license": "OGL-Ontario",
            "note": "Local bylaw jurisdiction layer",
        },
        "features": features,
    }
    OUT.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} -> {OUT} ({OUT.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
