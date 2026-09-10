#!/usr/bin/env python3
"""Convert official LIO CLUPAPRO shapefile to OpenWoodsMap crown_land.geojson.

Expects extract at:
  tools/gis/_tmp_clupapro/LIO-*/CLUPA_PROVINCIAL.shp
Download:
  https://ws.gisetl.lrc.gov.on.ca/fmedatadownload/Packages/CLUPAPRO.zip
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import shapefile
from shapely.geometry import mapping, shape
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / "tools/gis/_tmp_clupapro"
OUT = ROOT / "data/on/overlays/crown_land.geojson"


def find_shp() -> Path:
    matches = list(TMP.rglob("CLUPA_PROVINCIAL.shp"))
    if not matches:
        raise FileNotFoundError(f"No CLUPA_PROVINCIAL.shp under {TMP}")
    return matches[0]


def hunting_lookup(csv_path: Path) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    if not csv_path.exists():
        return out
    with csv_path.open(encoding="utf-8", errors="replace") as handle:
        reader = csv.reader(handle, delimiter=";")
        header = next(reader)
        idx = {name: i for i, name in enumerate(header)}
        for row in reader:
            if len(row) <= max(idx.values(), default=0):
                continue
            ogf = row[idx["OGF_ID"]]
            use_type = (row[idx["PERMITTED_USE_TYPE_ENG"]] or "").lower()
            flag = (row[idx["PERMITTED_FLG_ENG"]] or "").lower()
            if "hunt" in use_type:
                out.setdefault(ogf, set()).add(flag)
    return out


def main() -> int:
    shp = find_shp()
    csv_path = shp.parent / "CLUPA_POLICY_AND_PERMITTED_USE.csv"
    hunting = hunting_lookup(csv_path)
    reader = shapefile.Reader(str(shp))
    fields = [f[0] for f in reader.fields[1:]]
    features = []
    for i, sr in enumerate(reader.iterShapeRecords(), 1):
        rec = dict(zip(fields, sr.record))
        try:
            geometry = shape(sr.shape.__geo_interface__)
            if not geometry.is_valid:
                geometry = make_valid(geometry)
            geometry = geometry.simplify(0.0025, preserve_topology=True)
            if geometry.is_empty or geometry.geom_type == "GeometryCollection":
                continue
        except Exception as exc:  # noqa: BLE001
            print(f"skip {i}: {exc}", file=sys.stderr)
            continue
        policy = str(rec.get("POL_IDENT") or f"ON-{i}")
        designation = rec.get("DESIG_ENG") or rec.get("CATEGORY_E") or "Crown land use area"
        ogf = str(rec.get("OGF_ID") or "")
        flags = hunting.get(ogf, set())
        if flags:
            if "yes" in flags and "no" not in flags:
                allowed: bool | str = True
            elif "no" in flags and "yes" not in flags:
                allowed = False
            else:
                allowed = "conditional"
        else:
            allowed = False if "Park" in str(designation) else "conditional"
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "id": f"on-clupa-{policy}".replace(" ", "-"),
                    "name": rec.get("NAME_ENG") or policy,
                    "designation": designation,
                    "category": rec.get("CATEGORY_E") or "",
                    "policy_id": policy,
                    "hunting_allowed": allowed,
                    "summary": (
                        f"{designation}. Policy {policy}. "
                        "Ontario CLUPA Provincial (OGL-Ontario). "
                        "Verify current regulations before hunting."
                    ),
                    "source": "Ontario LIO CLUPAPRO shapefile (OGL-Ontario)",
                    "updated": "2026-09-06",
                    "province": "ON",
                    "ogf_id": ogf,
                },
                "geometry": mapping(geometry),
            }
        )
        if i % 200 == 0:
            print(f"  {i}/{len(reader)}", flush=True)

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "crown_land",
            "feature_count": len(features),
            "coverage": "Ontario CLUPA Provincial complete (CLUPAPRO shapefile)",
            "license": "OGL-Ontario",
            "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
            "source": "https://ws.gisetl.lrc.gov.on.ca/fmedatadownload/Packages/CLUPAPRO.zip",
        },
        "features": features,
    }
    OUT.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} -> {OUT} ({OUT.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
