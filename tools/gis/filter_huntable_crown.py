#!/usr/bin/env python3
"""Build a hunter-facing crown_land overlay from CLUPA + MNR unpatented tenure.

iHunter / Crown Land Use Atlas style:
  1. Keep CLUPA designations that are typically publicly huntable
     (General Use Area, Enhanced Management Area, etc.).
  2. Drop parks / conservation / wilderness (those stay on the parks layer).
  3. Intersect remaining polygons with Crown Land – MNR Unpatented Land so
     only actual Crown tenure is painted green (not patented private lots
     under broad GUA policy fills).

Reads:
  data/on/overlays/crown_land.clupa_full.geojson (or crown_land.geojson)
  tools/gis/_tmp_patent/unpatented_crown.geojson  (fetch_unpatented_on.py)
Writes:
  data/on/overlays/crown_land.geojson
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from shapely import STRtree
from shapely.geometry import mapping, shape
from shapely.ops import unary_union
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
CROWN = ROOT / "data/on/overlays/crown_land.geojson"
UNPATENTED = (
    Path(__file__).resolve().parent / "_tmp_patent" / "unpatented_crown.geojson"
)

HUNTABLE_DESIGNATIONS = {
    "General Use Area",
    "Enhanced Management Area",
    "Forest Reserve",
    "Provincial Wildlife Area",
    "Crown land use area",
}

PROTECTED_DESIGNATIONS = {
    "Provincial Park",
    "Conservation Reserve",
    "Wilderness Area",
    "Recommended Provincial Park",
    "Recommended Conservation Reserve",
    "Protected Area - Far North",
}


def load_geoms(path: Path) -> list:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    geoms = []
    for feature in data.get("features", []):
        try:
            geom = shape(feature["geometry"])
            if not geom.is_valid:
                geom = make_valid(geom)
            if not geom.is_empty:
                geoms.append(geom)
        except Exception as exc:  # noqa: BLE001
            print(f"skip tenure geom: {exc}", file=sys.stderr)
    print(f"Tenure mask: {len(geoms)} parcels from {path}", flush=True)
    return geoms


def intersect_tenure(geom, tree: STRtree, parcels: list):
    hits = tree.query(geom)
    if len(hits) == 0:
        return geom.__class__(), False  # empty same type
    pieces = []
    for idx in hits:
        other = parcels[int(idx)]
        if other.intersects(geom):
            pieces.append(other)
    if not pieces:
        return geom.__class__(), False
    mask = unary_union(pieces)
    if not mask.is_valid:
        mask = make_valid(mask)
    clipped = geom.intersection(mask)
    if not clipped.is_valid:
        clipped = make_valid(clipped)
    return clipped, True


def normalize_geom(geom, simplify_tol: float):
    if geom.is_empty:
        return None
    if geom.geom_type == "GeometryCollection":
        polys = [
            g
            for g in geom.geoms
            if g.geom_type in {"Polygon", "MultiPolygon"} and not g.is_empty
        ]
        if not polys:
            return None
        geom = unary_union(polys)
    if geom.geom_type not in {"Polygon", "MultiPolygon"}:
        return None
    if simplify_tol > 0:
        geom = geom.simplify(simplify_tol, preserve_topology=True)
        if not geom.is_valid:
            geom = make_valid(geom)
    if geom.is_empty:
        return None
    return geom


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--backup",
        action="store_true",
        help="Copy current crown_land.geojson to crown_land.clupa_full.geojson first",
    )
    parser.add_argument("--input", type=Path, default=None)
    parser.add_argument("--unpatented", type=Path, default=UNPATENTED)
    parser.add_argument(
        "--simplify",
        type=float,
        default=0.0002,
        help="Simplify clipped result (degrees)",
    )
    args = parser.parse_args()

    backup = CROWN.with_name("crown_land.clupa_full.geojson")
    if args.input is not None:
        source = args.input
    elif backup.exists():
        source = backup
    else:
        source = CROWN

    if not source.exists():
        print(f"Missing input {source}", file=sys.stderr)
        return 1

    if source.resolve() == CROWN.resolve() and not backup.exists():
        shutil.copy2(CROWN, backup)
        print(f"Saved full CLUPA backup -> {backup}")
        source = backup
    elif args.backup and source.resolve() == CROWN.resolve():
        shutil.copy2(CROWN, backup)
        print(f"Backed up full CLUPA -> {backup}")
        source = backup

    parcels = load_geoms(args.unpatented)
    if not parcels:
        print(
            f"Missing/empty unpatented file at {args.unpatented}. "
            "Run: python fetch_unpatented_on.py",
            file=sys.stderr,
        )
        return 1
    tree = STRtree(parcels)

    data = json.loads(source.read_text(encoding="utf-8"))
    kept = []
    dropped_protected = 0
    dropped_other = 0
    clipped_n = 0
    emptied = 0

    for i, feature in enumerate(data.get("features", []), 1):
        props = dict(feature.get("properties") or {})
        designation = str(props.get("designation") or "").strip()
        if designation in PROTECTED_DESIGNATIONS:
            dropped_protected += 1
            continue
        if designation not in HUNTABLE_DESIGNATIONS:
            dropped_other += 1
            continue
        try:
            geom = shape(feature["geometry"])
            if not geom.is_valid:
                geom = make_valid(geom)
            geom, changed = intersect_tenure(geom, tree, parcels)
            if changed:
                clipped_n += 1
            geom = normalize_geom(geom, args.simplify)
            if geom is None:
                emptied += 1
                continue
            props["layer_role"] = "huntable_crown"
            kept.append(
                {
                    "type": "Feature",
                    "properties": props,
                    "geometry": mapping(geom),
                }
            )
        except Exception as exc:  # noqa: BLE001
            print(f"skip feature {props.get('policy_id')}: {exc}", file=sys.stderr)
        if i % 100 == 0:
            print(f"  processed {i} CLUPA features …", flush=True)

    meta = dict(data.get("metadata") or {})
    meta.update(
        {
            "layer": "crown_land",
            "layer_role": "huntable_crown",
            "feature_count": len(kept),
            "coverage": (
                "Ontario huntable Crown land (CLUPA GUA/EMA/etc. intersected "
                "with MNR Unpatented Land tenure)"
            ),
            "filter": {
                "keep_designations": sorted(HUNTABLE_DESIGNATIONS),
                "drop_designations": sorted(PROTECTED_DESIGNATIONS),
                "tenure_intersect": (
                    "LIO Crown Land – MNR Unpatented Land (Open08/34)"
                ),
                "note": (
                    "Green ≈ designation-allowed Crown that is still "
                    "MNR-unpatented tenure. Verify on the ground; not a "
                    "legal survey."
                ),
            },
            "source_features": len(data.get("features", [])),
            "dropped_protected": dropped_protected,
            "dropped_other": dropped_other,
            "features_intersected_with_tenure": clipped_n,
            "features_emptied_by_tenure": emptied,
            "unpatented_parcel_count": len(parcels),
        }
    )
    payload = {
        "type": "FeatureCollection",
        "metadata": meta,
        "features": kept,
    }
    CROWN.write_text(json.dumps(payload), encoding="utf-8")
    print(
        f"Wrote {len(kept)} huntable features -> {CROWN} "
        f"({CROWN.stat().st_size / 1e6:.2f} MB); "
        f"dropped_protected={dropped_protected} dropped_other={dropped_other} "
        f"tenure_clips={clipped_n} emptied={emptied}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
