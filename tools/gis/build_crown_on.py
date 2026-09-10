#!/usr/bin/env python3
"""Build Ontario crown_land from actual Crown tenure parcels.

Previous approach painted CLUPA *policy* polygons (1,261 province-wide, very
coarse) and clipped them to tenure. That under-reported real Crown land by
orders of magnitude: e.g. ~909 Crown parcels exist around Bancroft while the
policy-derived layer produced 5 shapes.

This builder instead uses the authoritative parcel layer:

  Crown Land - MNR Unpatented Land (LIO Open08/34, ~62k parcels)

and joins Crown Land Use Policy Atlas attributes (designation, policy id,
official hunting permitted-use flag) onto each parcel where CLUPA covers it.

Inputs
  tools/gis/_tmp_patent/unpatented_crown.geojson   (fetch_unpatented_on.py)
  tools/gis/_tmp_clupapro/**/CLUPA_PROVINCIAL.shp  (+ policy CSVs)
  data/on/overlays/parks.geojson                   (to flag restricted parcels)
  tools/gis/_tmp_hydro/ohn_waterbody.geojson       (fetch_hydrography_on.py,
                                                    to flag lake beds; optional)

Output
  data/on/overlays/crown_land.geojson
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.ops import transform
from shapely.strtree import STRtree
from shapely.validation import make_valid

csv.field_size_limit(10_000_000)

ROOT = Path(__file__).resolve().parents[2]
GIS = Path(__file__).resolve().parent
UNPATENTED = GIS / "_tmp_patent" / "unpatented_crown.geojson"
CLUPA_TMP = GIS / "_tmp_clupapro"
PARKS = ROOT / "data/on/overlays/parks.geojson"
WATER = GIS / "_tmp_hydro" / "ohn_waterbody.geojson"
OUT = ROOT / "data/on/overlays/crown_land.geojson"

LICENSE = "OGL-Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"
TENURE_SOURCE = "LIO Crown Land – MNR Unpatented Land (Open08/34)"

# CLUPA designations where hunting is normally prohibited/heavily restricted.
PROTECTED_DESIGNATIONS = {
    "provincial park",
    "recommended provincial park",
    "wilderness area",
    "national park",
}

# Above this share of water, a parcel is reported as being a lake or river bed.
#
# Ontario's tenure record covers those beds, which is correct — a lake bed is
# unpatented Crown land — but the card in the middle of Round Lake was word for
# word the card on dry ground. Measured against the province's 1:500,000
# hydrography the distribution is strongly bimodal: 32,118 of 42,713 parcels are
# under 10% water and 4,844 are over 90%, with only a few hundred per decile in
# between. 0.9 sits in that gap. It flags Round Lake at 98% and Burns Lake at
# 96%, the two places iHunter and our card disagreed over open water, and leaves
# the Madawaska Highlands at 2% and Conroys Marsh at 14% alone.
#
# The flag is a fact about the parcel and not about the tap, and the note says so.
# Round Lake's bed is 2,625 ha, so its dry 2% is still ~50 ha: the Bonnechere site
# 240 m inland from the water's edge sits inside this parcel and is flagged. A
# per-point answer would need the hydrography in the pack, and 55,000 waterbodies
# is 39 MB against a 65 MB pack, so the honest move is the one the parks layer
# already makes for an opening described in words — state what is known about the
# outline and say plainly that it cannot place you inside it.
WATER_FRACTION = 0.9


def load_geojson(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def valid(geom):
    if not geom.is_valid:
        geom = make_valid(geom)
    return geom


def quantize(geom, decimals: int):
    """Round coordinates; ~5 decimals is ~1 m and roughly halves file size."""
    if decimals <= 0:
        return geom

    def _round(x, y, z=None):
        if z is None:
            return (round(x, decimals), round(y, decimals))
        return (round(x, decimals), round(y, decimals), z)

    out = transform(_round, geom)
    return valid(out)


def read_csv_rows(path: Path):
    with path.open(encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.reader(handle, delimiter=";")
        header = next(reader)
        idx = {name: i for i, name in enumerate(header)}
        for row in reader:
            if len(row) >= len(header):
                yield idx, row


def find(name: str) -> Path | None:
    matches = list(CLUPA_TMP.rglob(name))
    return matches[0] if matches else None


def clupa_hunting_by_ident() -> dict[str, object]:
    """POL_IDENT -> True/False/'conditional' from official permitted uses."""
    policy_csv = find("CLUPA_POLICY.csv")
    uses_csv = find("CLUPA_POLICY_AND_PERMITTED_USE.csv")
    if not policy_csv or not uses_csv:
        print("  (CLUPA policy CSVs unavailable; skipping hunting join)")
        return {}

    ident_by_ogf: dict[str, str] = {}
    for idx, row in read_csv_rows(policy_csv):
        ident_by_ogf[row[idx["OGF_ID"]].strip()] = row[idx["POLICY_IDENT"]].strip()

    rows_by_ident: dict[str, list[tuple[str, str]]] = {}
    for idx, row in read_csv_rows(uses_csv):
        use = (row[idx["PERMITTED_USE_TYPE_ENG"]] or "").strip()
        if "hunt" not in use.lower():
            continue
        ident = ident_by_ogf.get(row[idx["CLUPA_POLICY_ID"]].strip())
        if not ident:
            continue
        rows_by_ident.setdefault(ident, []).append(
            (use, (row[idx["PERMITTED_FLG_ENG"]] or "").strip().lower())
        )

    verdicts: dict[str, object] = {}
    for ident, rows in rows_by_ident.items():
        general = [flag for use, flag in rows if use.lower() == "hunting"]
        flags = set(general) if general else {flag for _, flag in rows}
        if flags == {"yes"}:
            verdict: object = True
            if any(flag == "no" for _, flag in rows):
                verdict = "conditional"
        elif flags == {"no"}:
            verdict = False
        else:
            verdict = "conditional"
        verdicts[ident] = verdict
    print(f"  CLUPA hunting verdicts for {len(verdicts)} policies")
    return verdicts


def load_clupa_polygons():
    """Return (tree, records) of CLUPA primary policy polygons."""
    shp_path = find("CLUPA_PROVINCIAL.shp")
    if not shp_path:
        print("  (CLUPA shapefile unavailable; parcels will have no designation)")
        return None, []
    try:
        import shapefile  # pyshp
    except ImportError:
        print("  (pyshp missing; skipping CLUPA attribute join)")
        return None, []

    reader = shapefile.Reader(str(shp_path))
    fields = [f[0] for f in reader.fields[1:]]
    geoms = []
    records = []
    try:
        for sr in reader.iterShapeRecords():
            attrs = dict(zip(fields, sr.record, strict=False))
            # Overlays are supplementary policy layers; prefer primary areas.
            if str(attrs.get("OVERLAY") or "").strip().lower() in {"y", "yes", "1"}:
                continue
            try:
                geom = valid(shape(sr.shape.__geo_interface__))
            except Exception:  # noqa: BLE001
                continue
            if geom.is_empty:
                continue
            geoms.append(geom)
            records.append(
                {
                    "policy_id": str(attrs.get("POL_IDENT") or "").strip(),
                    "name": str(attrs.get("NAME_ENG") or "").strip(),
                    "designation": str(attrs.get("DESIG_ENG") or "").strip(),
                    "category": str(attrs.get("CATEGORY_E") or "").strip(),
                }
            )
    finally:
        reader.close()
    print(f"  CLUPA primary policy polygons: {len(geoms)}")
    return STRtree(geoms), (geoms, records)


def load_parks_tree():
    if not PARKS.is_file():
        return None, []
    data = load_geojson(PARKS)
    geoms = []
    names = []
    for feature in data.get("features") or []:
        try:
            geom = valid(shape(feature["geometry"]))
        except Exception:  # noqa: BLE001
            continue
        if geom.is_empty:
            continue
        geoms.append(geom)
        names.append((feature.get("properties") or {}).get("name") or "Protected area")
    print(f"  parks/conservation polygons: {len(geoms)}")
    return (STRtree(geoms) if geoms else None), (geoms, names)


def load_water_tree():
    """Waterbody footprints, for telling a lake bed from dry ground.

    Absence is tolerated: without it every parcel simply goes unflagged, which is
    the behaviour that shipped before and is wrong in a way the card can survive.
    A partial extract would be worse, so fetch_hydrography_on.py refuses to cache
    one.
    """
    if not WATER.is_file():
        print(
            f"  no hydrography at {WATER}; parcels will not be flagged as water. "
            "Run: python fetch_hydrography_on.py",
            file=sys.stderr,
        )
        return None, []
    data = load_geojson(WATER)
    geoms = []
    for feature in data.get("features") or []:
        try:
            geom = valid(shape(feature["geometry"]))
        except Exception:  # noqa: BLE001
            continue
        if geom.is_empty or geom.geom_type not in {"Polygon", "MultiPolygon"}:
            continue
        geoms.append(geom)
    print(f"  waterbodies: {len(geoms)}")
    return (STRtree(geoms) if geoms else None), geoms


def water_fraction(geom, tree, geoms) -> float:
    """Share of a parcel's footprint covered by water, 0 where unknown."""
    if tree is None:
        return 0.0
    wet = 0.0
    for hit in tree.query(geom):
        overlap = geoms[int(hit)].intersection(geom)
        if not overlap.is_empty:
            wet += overlap.area
    return min(wet / geom.area, 1.0) if geom.area > 0 else 0.0


# Per-feature prose is rendered in the app from these codes so that 40k+
# parcels do not each carry a duplicated paragraph.
BASIS_CODES = {
    "protected_area": (
        "Crown tenure inside a provincial park or conservation reserve. Hunting "
        "is generally prohibited or tightly restricted — confirm the park's own "
        "regulations."
    ),
    "clupa": (
        "Hunting status comes from the Crown Land Use Policy Atlas permitted-use "
        "table for this policy. Open the policy for the official wording."
    ),
    "designation": (
        "Hunting status inferred from the land use designation covering this "
        "parcel."
    ),
    # Roughly half of Ontario's Crown land by area sits outside the CLUPA
    # planning area, most of it in the Far North. That is an absence of an
    # area-specific policy, not an absence of a rule, so the note states the
    # province's own general position and then names what the map cannot see.
    "tenure_only": (
        "No area-specific land use policy covers this parcel. Ontario lists "
        "hunting among the activities you can usually do on Crown land with a "
        "valid licence, so the general rules govern here: provincial seasons "
        "and licence requirements, firearm rules, and municipal discharge "
        "by-laws. This map cannot see posted signage, an active land use "
        "permit or lease, or a local access restriction, and any of those can "
        "override the general rule on the ground."
    ),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unpatented", type=Path, default=UNPATENTED)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument(
        "--min-area-ha",
        type=float,
        default=0.5,
        help="Drop slivers smaller than this (default 0.5 ha)",
    )
    parser.add_argument(
        "--simplify",
        type=float,
        default=0.00015,
        help="Extra simplify tolerance in degrees (~15 m)",
    )
    parser.add_argument(
        "--precision",
        type=int,
        default=5,
        help="Coordinate decimals to keep (5 ≈ 1 m)",
    )
    args = parser.parse_args()

    if not args.unpatented.is_file():
        print(
            f"Missing {args.unpatented}. Run: python fetch_unpatented_on.py",
            file=sys.stderr,
        )
        return 1

    print("Loading Crown tenure parcels …", flush=True)
    tenure = load_geojson(args.unpatented)
    parcels = tenure.get("features") or []
    print(f"  parcels: {len(parcels)}")

    print("Loading CLUPA policy attributes …", flush=True)
    hunting_by_ident = clupa_hunting_by_ident()
    clupa_tree, clupa_payload = load_clupa_polygons()
    clupa_geoms, clupa_records = clupa_payload if clupa_payload else ([], [])

    print("Loading parks …", flush=True)
    parks_tree, parks_payload = load_parks_tree()
    parks_geoms, parks_names = parks_payload if parks_payload else ([], [])

    print("Loading hydrography …", flush=True)
    water_tree, water_geoms = load_water_tree()

    out: list[dict] = []
    dropped_small = 0
    matched_policy = 0
    in_park = 0
    over_water = 0

    for i, feature in enumerate(parcels, 1):
        geometry = feature.get("geometry")
        if not geometry:
            continue
        try:
            geom = valid(shape(geometry))
        except Exception:  # noqa: BLE001
            continue
        if geom.is_empty or geom.geom_type not in {"Polygon", "MultiPolygon"}:
            continue

        # Rough hectares: 1 deg^2 ~ 111.32km x 111.32km*cos(lat)
        centroid = geom.representative_point()
        import math

        lat_scale = math.cos(math.radians(centroid.y))
        area_ha = geom.area * (111_320**2) * lat_scale / 10_000
        if area_ha < args.min_area_ha:
            dropped_small += 1
            continue

        if args.simplify > 0:
            geom = valid(geom.simplify(args.simplify, preserve_topology=True))
        geom = quantize(geom, args.precision)
        if geom.is_empty or geom.geom_type not in {"Polygon", "MultiPolygon"}:
            dropped_small += 1
            continue

        props = feature.get("properties") or {}
        designation = ""
        policy_id = ""
        policy_name = ""
        if clupa_tree is not None:
            for hit in clupa_tree.query(centroid):
                record = clupa_records[int(hit)]
                if clupa_geoms[int(hit)].contains(centroid):
                    designation = record["designation"]
                    policy_id = record["policy_id"]
                    policy_name = record["name"]
                    break

        park_name = None
        if parks_tree is not None:
            for hit in parks_tree.query(centroid):
                if parks_geoms[int(hit)].contains(centroid):
                    park_name = parks_names[int(hit)]
                    break

        hunting: object
        basis: str
        if park_name:
            hunting = False
            basis = "protected_area"
            in_park += 1
        elif policy_id and policy_id in hunting_by_ident:
            hunting = hunting_by_ident[policy_id]
            basis = "clupa"
        elif designation and designation.strip().lower() in PROTECTED_DESIGNATIONS:
            hunting = False
            basis = "designation"
        else:
            hunting = None
            basis = "tenure_only"
        if policy_id:
            matched_policy += 1

        properties: dict[str, object] = {
            "id": f"on-crown-{props.get('ogf_id') or i}",
            "hunting_allowed": hunting,
            "basis": basis,
            "area_ha": round(area_ha, 1),
        }
        name = (policy_name or "").strip()
        if name:
            properties["name"] = name
        if designation:
            properties["designation"] = designation
        if policy_id:
            properties["policy_id"] = policy_id
        if park_name:
            properties["within"] = park_name
        # Measured on the simplified footprint, which is what the map draws and
        # what the user tapped, so the flag and the outline agree.
        if water_fraction(geom, water_tree, water_geoms) >= WATER_FRACTION:
            properties["over_water"] = True
            over_water += 1

        out.append(
            {
                "type": "Feature",
                "properties": properties,
                "geometry": mapping(geom),
            }
        )
        if i % 5000 == 0:
            print(f"  processed {i}/{len(parcels)} parcels …", flush=True)

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "crown_land",
            "layer_role": "crown_tenure",
            "feature_count": len(out),
            "coverage": (
                "Ontario Crown land parcels (MNR unpatented tenure), with Crown "
                "Land Use Policy Atlas designation and permitted-use hunting flags"
            ),
            "boundary_accuracy": "mapped",
            "accuracy_note": (
                "Parcel boundaries are mapped from provincial land tenure records "
                "and are not a legal survey. The shading means Crown tenure, not "
                "permission to hunt."
            ),
            "default_name": "Crown land",
            "tenure": "Crown land — Ministry unpatented",
            "basis_notes": BASIS_CODES,
            "water_note": (
                "Almost all of this parcel is water: it is a lake or river bed, "
                "which Ontario's tenure record covers as Crown land, and hunting "
                "over Crown water is not closed. This outline cannot tell you "
                "whether your own spot is wet or dry — the shoreline inside it is "
                "not drawn, and the hydrography behind this measurement is only "
                "1:500,000."
            ),
            "water_source": "Ontario LIO — OHN 500K Waterbody",
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": TENURE_SOURCE,
            "policy_source": "Ontario Crown Land Use Policy Atlas (CLUPAPRO)",
            "parcels_with_policy": matched_policy,
            "parcels_in_protected_area": in_park,
            "parcels_over_water": over_water,
            "dropped_slivers": dropped_small,
        },
        "features": out,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    print(
        f"Wrote {len(out)} Crown parcels -> {args.out} "
        f"({args.out.stat().st_size / 1e6:.2f} MB); "
        f"with_policy={matched_policy} in_park={in_park} "
        f"over_water={over_water} slivers={dropped_small}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
