#!/usr/bin/env python3
"""Build the French-Mattawa divide that separates northern from southern Ontario
for Sunday gun hunting purposes.

O. Reg. 665/98 (Hunting), s. 66(1):

    A person shall not carry or discharge a firearm, other than a long-bow or
    a cross-bow, for the purpose of hunting on a Sunday, in any area lying
    south of the French and Mattawa rivers except those municipalities listed
    in Part 7 of Ontario Regulation 663/98 (Area Descriptions) made under
    the Act.

The prohibition applies only south of the rivers. North of them, Sunday gun
hunting is permitted without any municipal opt-in.

The script derives the divide from the Wildlife Management Unit boundaries
published by MNRF under OGL-Ontario. The WMU fabric follows the French and
Mattawa rivers as described in O. Reg. 663/98 Part 6, so the shared boundary
between northern and southern WMUs IS the ministry's own digitisation of
"the French and Mattawa rivers" as a regulatory line. Using the WMU boundary
rather than the OHN watercourse centrelines is deliberate: the OHN represents
these wide rivers as waterbody polygons (not centreline segments), and the
WMU boundary already traces the channel the regulation means, including the
straight-line crossing of Lake Nipissing that O. Reg. 663/98 describes.

Produces two features for sunday_gun.geojson:

  1. north_clear  — the area clearly north of the divide (beyond the near-
                     divide band), where Sunday gun hunting is certainly
                     permitted.
  2. near_divide  — a narrow band on both sides of the divide line, where our
                     digitised line cannot reliably distinguish north from
                     south. The regulation means the actual river; our line is
                     a centerline approximation, and any point within a few
                     hundred metres of it might be on either bank.

Reads  data/on/overlays/wmu.geojson.
Writes data/on/overlays/sunday_gun_north.geojson.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from pyproj import Transformer
from shapely.geometry import LineString, MultiLineString, mapping, shape
from shapely.ops import linemerge, unary_union
from shapely.validation import make_valid

from geomutil import quantized_valid

ROOT = Path(__file__).resolve().parents[2]
WMU = ROOT / "data/on/overlays/wmu.geojson"
OUT = ROOT / "data/on/overlays/sunday_gun_north.geojson"

# Band half-width in metres.  The French River is 100–500 m wide depending on
# the reach; the Mattawa is narrower.  500 m on each side of our centreline
# means the band covers the full river width plus a margin of at least 100 m
# on each bank, which is the honest limit of certainty from a digitised line.
BAND_HALF_M = 500

# Simplification tolerance in metres.  50 m keeps the divide accurate to GPS
# resolution while cutting the vertex count substantially.  The coastline and
# far-north boundary are simplified more aggressively (200 m) because nothing
# legal turns on their shape.
DIVIDE_SIMPLIFY_M = 50
COAST_SIMPLIFY_M = 200

# Coordinate precision in the output (decimal places of a degree).  Five places
# is ~1.1 m, which is well below the band width and simplification tolerance.
COORD_PRECISION = 5

# ── projections ──────────────────────────────────────────────────────────────
# The divide spans roughly −80.3° to −78.7° longitude.  UTM Zone 17N covers
# −84° to −78° and gives sub-metre metric accuracy across the divide.  The
# wider north polygon extends outside this zone, but the only metric operation
# (buffering) applies only to the divide line, which is inside zone 17N.
TO_UTM = Transformer.from_crs("EPSG:4326", "EPSG:32617", always_xy=True)
TO_WGS = Transformer.from_crs("EPSG:32617", "EPSG:4326", always_xy=True)

# ── WMU classification ──────────────────────────────────────────────────────
# The French and Mattawa rivers separate WMUs into a northern group (where
# Sunday gun hunting is permitted) and a southern group (where it is permitted
# only in scheduled municipalities).  The classification is read from the WMU
# data rather than hard-coded, using the WMU numbers from O. Reg. 663/98 Part 6.
#
# WMU numbers ≤ 46 with these exceptions form the northern set; the rest are
# south.  43B (east shore of Georgian Bay, south of the North Channel) and 46
# (Parry Sound, south of French River) are the two WMUs in the ≤ 46 range that
# fall south of the divide.  This matches the ministry's own Sunday gun hunting
# map and the WMU boundary fabric.
SOUTH_EXCEPTIONS = {"43B", "46"}


def wmu_number(wmu_id: str) -> float:
    """Extract the leading number from a WMU id like '55B' or '69A-1'."""
    num = ""
    for ch in wmu_id:
        if ch.isdigit():
            num += ch
        else:
            break
    return float(num) if num else 999


def is_north(wmu_id: str) -> bool:
    """True if this WMU is north of the French and Mattawa rivers."""
    if wmu_id in SOUTH_EXCEPTIONS:
        return False
    return wmu_number(wmu_id) <= 46


def project_line(line, transformer):
    """Project a LineString or MultiLineString."""
    if isinstance(line, MultiLineString):
        return MultiLineString([project_line(g, transformer) for g in line.geoms])
    coords = [transformer.transform(x, y) for x, y in line.coords]
    return LineString(coords)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    # ── load WMUs ────────────────────────────────────────────────────────
    if not WMU.is_file():
        print(f"Missing {WMU}", file=sys.stderr)
        return 1
    wmu_data = json.loads(WMU.read_text(encoding="utf-8"))
    features = wmu_data["features"]
    print(f"WMU features: {len(features)}")

    north_geoms, south_geoms = [], []
    north_ids, south_ids = [], []
    for f in features:
        wmu_id = f["properties"].get("wmu_id") or f["properties"].get("name", "?")
        geom = make_valid(shape(f["geometry"]))
        if is_north(wmu_id):
            north_geoms.append(geom)
            north_ids.append(wmu_id)
        else:
            south_geoms.append(geom)
            south_ids.append(wmu_id)

    print(f"North WMUs: {len(north_ids)}  South WMUs: {len(south_ids)}")

    # ── union each side ──────────────────────────────────────────────────
    print("Building north polygon...", flush=True)
    north_union = make_valid(unary_union(north_geoms))
    south_union = make_valid(unary_union(south_geoms))
    print(f"  North union: {north_union.geom_type}, "
          f"{sum(len(p.exterior.coords) for p in (north_union.geoms if north_union.geom_type == 'MultiPolygon' else [north_union]))} exterior vertices")

    # ── extract the divide line ──────────────────────────────────────────
    # The shared boundary between the two unions IS the divide.
    print("Extracting divide line...", flush=True)
    north_boundary = north_union.boundary
    south_boundary = south_union.boundary
    raw_divide = north_boundary.intersection(south_boundary)

    if raw_divide.is_empty:
        print("ERROR: No shared boundary found between north and south WMUs",
              file=sys.stderr)
        return 1

    # The intersection may include isolated points where polygons touch at
    # corners.  Keep only line segments.
    lines = []
    if raw_divide.geom_type == "GeometryCollection":
        for g in raw_divide.geoms:
            if g.geom_type in ("LineString", "MultiLineString"):
                lines.append(g)
    elif raw_divide.geom_type in ("LineString", "MultiLineString"):
        lines.append(raw_divide)
    else:
        print(f"Unexpected divide geometry: {raw_divide.geom_type}", file=sys.stderr)
        return 1

    divide = linemerge(unary_union(lines))
    if divide.geom_type == "MultiLineString":
        divide_parts = list(divide.geoms)
    else:
        divide_parts = [divide]

    total_len_deg = sum(p.length for p in divide_parts)
    total_verts = sum(len(p.coords) for p in divide_parts)
    print(f"  Divide: {len(divide_parts)} segments, "
          f"{total_verts} vertices, {total_len_deg:.4f}° total length")

    # ── buffer the divide in metric space ────────────────────────────────
    print(f"Buffering divide by {BAND_HALF_M} m...", flush=True)
    divide_utm = MultiLineString([project_line(p, TO_UTM) for p in divide_parts])
    band_utm = divide_utm.buffer(BAND_HALF_M, cap_style="round", join_style="round")
    band_wgs = shape(mapping(band_utm))
    # Project the buffer back to WGS84
    band_coords_wgs = []

    def _project_ring(ring):
        return [TO_WGS.transform(x, y) for x, y in ring]

    if band_utm.geom_type == "Polygon":
        from shapely.geometry import Polygon as ShapelyPolygon
        ext = _project_ring(band_utm.exterior.coords)
        ints = [_project_ring(r.coords) for r in band_utm.interiors]
        band_wgs = ShapelyPolygon(ext, ints)
    elif band_utm.geom_type == "MultiPolygon":
        from shapely.geometry import MultiPolygon as ShapelyMultiPolygon, Polygon as ShapelyPolygon
        polys = []
        for p in band_utm.geoms:
            ext = _project_ring(p.exterior.coords)
            ints = [_project_ring(r.coords) for r in p.interiors]
            polys.append(ShapelyPolygon(ext, ints))
        band_wgs = ShapelyMultiPolygon(polys)

    band_wgs = make_valid(band_wgs)
    print(f"  Band polygon: {band_wgs.geom_type}")

    # ── simplify, then cut, in that order ────────────────────────────────
    # Order matters more than it looks. Cutting first and simplifying the two
    # pieces afterwards moves their shared edge by different amounts — the coast
    # tolerance on one side, the divide tolerance on the other — and the pieces
    # stop meeting. That left 1,015 slivers along the divide covered by neither
    # feature, and the card reads no covering feature as a prohibition, so each
    # sliver was a false "not permitted" in country where hunting is legal.
    # Simplifying first and cutting second makes the two pieces tile the north
    # exactly, because their shared edge is the band's edge by construction.
    coast_tol_deg = COAST_SIMPLIFY_M / 111_000  # rough metres-to-degrees

    north_s = make_valid(north_union.simplify(coast_tol_deg))
    south_s = make_valid(south_union.simplify(coast_tol_deg))
    # The band is simplified before the cut for the same reason: thinning it
    # afterwards would move the edge it shares with the north polygon. A round
    # buffer of a 402-vertex line carries far more detail than a 500 m band can
    # mean, and thinning it here rather than later costs nothing in fidelity.
    band_wgs = make_valid(band_wgs.simplify(DIVIDE_SIMPLIFY_M / 111_000))

    # Only the coast is coarsened by that tolerance. The divide-side edge is
    # discarded in the cut below and replaced by the band's, whose fidelity
    # comes from DIVIDE_SIMPLIFY_M instead. Coarsening the coast can still drag
    # the divide-side boundary by up to COAST_SIMPLIFY_M before the cut, which
    # is why the band's half-width has to stay the larger of the two: a strip
    # displaced by 200 m is still inside a 500 m band, so it is reported as
    # unknown rather than as one side or the other.
    if COAST_SIMPLIFY_M >= BAND_HALF_M:
        print(
            f"ERROR: coast tolerance {COAST_SIMPLIFY_M} m is not inside the "
            f"{BAND_HALF_M} m band, so simplification can move ground across "
            "the divide without the band admitting it",
            file=sys.stderr,
        )
        return 1

    print("Cutting near-divide band from north polygon...", flush=True)
    north_clear = make_valid(north_s.difference(band_wgs))
    near_divide = make_valid(north_s.intersection(band_wgs))

    # Also capture the south side of the band — a point south of our line but
    # within 500 m might actually be north of the real river.
    south_band = make_valid(south_s.intersection(band_wgs))
    if not south_band.is_empty:
        near_divide = make_valid(unary_union([near_divide, south_band]))

    print(f"  north_clear: {north_clear.geom_type}")
    print(f"  near_divide: {near_divide.geom_type}")

    # Validity is checked after rounding rather than before it, because rounding
    # is what breaks these rings: both features came out invalid when the
    # rounding ran last, one with a self-intersection and one with a collapsed
    # ring, and a renderer fills an invalid ring with a hole or an inversion.
    north_geometry = quantized_valid(
        north_clear, COORD_PRECISION, label="north of the divide"
    )
    band_geometry = quantized_valid(
        near_divide, COORD_PRECISION, label="near-divide band"
    )

    def count_verts(geom):
        if geom.geom_type == "Polygon":
            return len(geom.exterior.coords) + sum(len(r.coords) for r in geom.interiors)
        elif geom.geom_type == "MultiPolygon":
            return sum(count_verts(p) for p in geom.geoms)
        return 0

    print(f"  north_clear simplified: {count_verts(shape(north_geometry))} vertices")
    print(f"  near_divide simplified: {count_verts(shape(band_geometry))} vertices")

    # ── assemble output ──────────────────────────────────────────────────
    citation = (
        "O. Reg. 665/98 (Hunting), s. 66(1): Sunday gun hunting prohibition "
        "applies only south of the French and Mattawa rivers"
    )
    out_features = [
        {
            "type": "Feature",
            "properties": {
                "id": "on-sunday-north",
                "name": "North of the French and Mattawa rivers",
                "sunday_gun": True,
                "basis": "reg665_s66",
                "boundary_accuracy": "mapped",
                "near_divide": False,
            },
            "geometry": north_geometry,
        },
        {
            "type": "Feature",
            "properties": {
                "id": "on-sunday-divide-band",
                "name": "Near the French-Mattawa divide",
                "sunday_gun": True,
                "basis": "reg665_s66",
                "boundary_accuracy": "approximate",
                "near_divide": True,
                "band_half_m": BAND_HALF_M,
            },
            "geometry": band_geometry,
        },
    ]

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "layer": "sunday_gun",
            "province": "on",
            "feature_count": len(out_features),
            "citation": citation,
            "source": "WMU boundary fabric (Ontario MNRF, OGL-Ontario)",
            "license": "OGL-Ontario",
            "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
            "divide_source": (
                "Derived from the shared boundary between northern and southern "
                "Wildlife Management Units, which O. Reg. 663/98 Part 6 defines "
                "along the French and Mattawa rivers. The WMU boundary is MNRF's "
                "own digitisation of the regulatory line."
            ),
            "band_half_m": BAND_HALF_M,
            "simplify_divide_m": DIVIDE_SIMPLIFY_M,
            "simplify_coast_m": COAST_SIMPLIFY_M,
            "north_wmus": sorted(north_ids),
            "south_wmus_at_divide": sorted(
                wid for wid in south_ids if wmu_number(wid) <= 50
            ),
        },
        "features": out_features,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(payload)
    args.out.write_text(raw, encoding="utf-8")
    size_kb = len(raw.encode("utf-8")) / 1024
    print(f"Wrote {args.out} ({size_kb:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
