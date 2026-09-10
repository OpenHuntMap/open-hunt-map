#!/usr/bin/env python3
"""Fetch Quebec municipalities from Statistics Canada 2021 CSD boundaries.

Downloads the Cartographic Boundary File ZIP, filters PRUID=24, and
reprojects NAD83 / Statistics Canada Lambert (EPSG:3347) → WGS84.
Requires: pip install pyshp pyproj shapely
"""

from __future__ import annotations

import argparse
import json
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from pyproj import Transformer
from shapely.geometry import mapping, shape
from shapely.ops import transform
from shapely.validation import make_valid

try:
    import shapefile  # pyshp
except ImportError as exc:  # pragma: no cover
    raise SystemExit("pip install pyshp") from exc

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/qc/overlays/municipalities.geojson"
# 2021 Census Cartographic Boundary File — Census Subdivisions
ZIP_URL = (
    "https://www12.statcan.gc.ca/census-recensement/2021/geo/sip-pis/"
    "boundary-limites/files-fichiers/lcsd000b21a_e.zip"
)
SRC_CRS = "EPSG:3347"  # NAD83 / Statistics Canada Lambert


def download_zip(dest: Path) -> Path:
    if dest.exists() and dest.stat().st_size > 1_000_000:
        print(f"Using cached {dest}", flush=True)
        return dest
    print(f"Downloading {ZIP_URL} …", flush=True)
    req = urllib.request.Request(ZIP_URL, headers={"User-Agent": "OpenWoodsMap/0.1"})
    with urllib.request.urlopen(req, timeout=600) as response:
        dest.write_bytes(response.read())
    print(f"Saved {dest} ({dest.stat().st_size/1e6:.1f} MB)", flush=True)
    return dest


def find_shp(extract_dir: Path) -> Path:
    matches = list(extract_dir.rglob("*.shp"))
    if not matches:
        raise FileNotFoundError(f"No .shp under {extract_dir}")
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument(
        "--zip",
        type=Path,
        default=Path(__file__).resolve().parent / "_tmp_statcan" / "lcsd000b21a_e.zip",
    )
    parser.add_argument("--simplify", type=float, default=0.002)
    args = parser.parse_args()

    args.zip.parent.mkdir(parents=True, exist_ok=True)
    download_zip(args.zip)
    transformer = Transformer.from_crs(SRC_CRS, "EPSG:4326", always_xy=True)

    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(args.zip) as archive:
            archive.extractall(tmp)
        shp = find_shp(Path(tmp))
        print(f"Reading {shp.name} ({SRC_CRS} -> EPSG:4326) ...", flush=True)
        reader = shapefile.Reader(str(shp), encoding="latin-1")
        fields = [f[0] for f in reader.fields[1:]]
        out = []
        try:
            for i, sr in enumerate(reader.iterShapeRecords(), 1):
                attrs = dict(zip(fields, sr.record, strict=False))
                pruid = str(attrs.get("PRUID") or attrs.get("pruid") or "")
                if pruid != "24":
                    continue
                name = str(
                    attrs.get("CSDNAME")
                    or attrs.get("csdname")
                    or f"CSD {i}"
                ).strip()
                ctype = str(
                    attrs.get("CSDTYPE") or attrs.get("csdtype") or ""
                ).strip()
                try:
                    geom = sr.shape.__geo_interface__
                    g = shape(geom)
                    if not g.is_valid:
                        g = make_valid(g)
                    g = transform(transformer.transform, g)
                    if args.simplify > 0:
                        g = g.simplify(args.simplify, preserve_topology=True)
                    if g.is_empty or g.geom_type == "GeometryCollection":
                        continue
                    out.append(
                        {
                            "type": "Feature",
                            "properties": {
                                "id": f"qc-csd-{attrs.get('CSDUID') or i}",
                                "name": name,
                                "type": ctype or "municipality",
                                "province": "QC",
                                "source": (
                                    "Statistics Canada 2021 CSD cartographic "
                                    "boundaries"
                                ),
                            },
                            "geometry": mapping(g),
                        }
                    )
                except Exception as exc:  # noqa: BLE001
                    print(f"skip {name}: {exc}")
                if len(out) % 100 == 0 and out:
                    print(f"  kept {len(out)} …", flush=True)
        finally:
            reader.close()

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "layer": "municipalities",
            "feature_count": len(out),
            "coverage": "Quebec census subdivisions (2021)",
            "license": "Statistics Canada Open Licence",
            "source": ZIP_URL,
            "source_crs": SRC_CRS,
            "simplify_degrees": args.simplify,
        },
        "features": out,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(out)} -> {args.out} ({args.out.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
