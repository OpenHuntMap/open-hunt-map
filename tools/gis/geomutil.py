"""Shared geometry thinning for overlay builds.

Pack size is a hard constraint, so overlays are simplified. Done naively that
silently deletes features, and a deleted feature is a wrong answer: dropping a
municipality loses a bylaw jurisdiction, and dropping a narrow waterway park
loses somewhere hunting is actually permitted. The rules here keep the feature
and spend the savings on detail nobody needs instead.
"""

from __future__ import annotations

from shapely.geometry import MultiPolygon, Polygon, mapping, shape
from shapely.ops import unary_union
from shapely.validation import make_valid

# Roughly one hectare in square degrees at Ontario latitudes. Simplification
# cannot take a ring below four points, so shorelines made of thousands of bare
# rocks and lakes stay huge however hard they are simplified. Discarding the
# parts too small to read on a map is the only real saving available.
MIN_PART_AREA = 1e-6


def quantize(geometry: dict, digits: int = 5) -> dict:
    """Round GeoJSON coordinates to a fixed number of decimal places."""

    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def quantized_valid(geometry, digits: int = 5, label: str | None = None) -> dict:
    """Quantize, then repair, because rounding is what can break polygon rings.

    A narrow neck can round into a self-intersection. The repair is accepted
    only when it holds the feature's area within 0.1%: area measures the ground
    the parcel claims, while outline distance wrongly rejects removal of a
    zero-width spike whose length is real but whose area is nothing.

    When the target grid cannot hold a parcel, a finer one is tried before
    giving up on rounding. The parcels that fail are the ones with a neck
    narrower than the grid, and a finer grid is the direct answer to that; the
    alternative is float64 in full, which costs about 0.6 MB across the
    dispositions alone for sub-micron precision on a boundary the province
    surveyed to metres. Pack size is a real constraint, so a rung is worth more
    than a warning.
    """
    original = polygonal(valid(geometry))
    if not usable(original):
        if label:
            print(
                f"  WARNING: no usable polygonal geometry for {label}; "
                "keeping original geometry"
            )
        return mapping(geometry)
    # The last rung is roughly a tenth of a millimetre: past there the grid is no
    # longer what is wrong with the ring, and the parcel keeps its raw geometry.
    for grid in (digits, digits + 1, digits + 2, 9):
        rounded = quantize(mapping(original), grid)
        candidate = shape(rounded)
        if candidate.is_valid:
            if label and grid != digits:
                print(f"  {label}: quantized at {grid} decimals to stay valid")
            return rounded
        repaired = shape(quantize(mapping(candidate.buffer(0)), grid))
        if (
            repaired.is_valid
            and usable(repaired)
            and abs(repaired.area - candidate.area) <= candidate.area * 1e-3
        ):
            if label and grid != digits:
                print(f"  {label}: repaired at {grid} decimals to stay valid")
            return quantize(mapping(repaired), grid)
    if label:
        print(
            f"  WARNING: no grid holds {label}; keeping valid unrounded geometry"
        )
    return mapping(original)


def valid(geometry):
    if geometry.is_valid:
        return geometry
    return make_valid(geometry)


def usable(geometry) -> bool:
    return (
        geometry is not None
        and not geometry.is_empty
        and geometry.geom_type in {"Polygon", "MultiPolygon"}
    )


def polygonal(geometry):
    """Keep the area of a geometry, discarding linework make_valid handed back.

    Rounding or simplifying a multipart parcel collapses its hair-thin parts to
    zero width. make_valid then returns a GeometryCollection of the surviving
    polygons plus those degenerate rings as LineStrings, and a caller that tests
    `geom_type in {"Polygon", "MultiPolygon"}` throws the whole parcel away — in
    this repo that silently deleted 190 Crown parcels covering 2.46M ha,
    including a 970,000 ha block, and every one of them was counted as a sliver.
    So the collection is unpacked rather than rejected: the polygons are the
    ground the province actually mapped, and the lines are an artefact of our own
    arithmetic.
    """
    if geometry is None or geometry.is_empty:
        return None
    if geometry.geom_type in {"Polygon", "MultiPolygon"}:
        return geometry
    if geometry.geom_type != "GeometryCollection":
        return None
    parts = [
        part
        for part in geometry.geoms
        if part.geom_type in {"Polygon", "MultiPolygon"} and not part.is_empty
    ]
    if not parts:
        return None
    merged = unary_union(parts)
    merged = valid(merged)
    return merged if usable(merged) else None


def drop_small_holes(part, min_area: float = MIN_PART_AREA):
    """Remove negligible interior rings, such as small lakes."""
    if part.geom_type != "Polygon" or not part.interiors:
        return part
    holes = [ring for ring in part.interiors if Polygon(ring).area >= min_area]
    if len(holes) == len(part.interiors):
        return part
    return valid(Polygon(part.exterior, holes))


def thin(geometry, tolerance: float, min_part_area: float = MIN_PART_AREA):
    """Simplify part by part, never returning nothing.

    Parts smaller than min_part_area are dropped. If that would leave nothing,
    the largest part is kept even unsimplified, so the feature always survives.
    """
    if tolerance <= 0:
        return geometry
    parts = [p for p in getattr(geometry, "geoms", [geometry]) if not p.is_empty]
    if not parts:
        return geometry
    kept = []
    for part in parts:
        if part.area < min_part_area:
            continue
        thinned = valid(drop_small_holes(part, min_part_area)).simplify(
            tolerance, preserve_topology=True
        )
        if usable(thinned):
            kept.append(thinned)
    if not kept:
        largest = max(parts, key=lambda part: part.area)
        thinned = largest.simplify(tolerance, preserve_topology=True)
        return thinned if usable(thinned) else largest
    if len(kept) == 1:
        return kept[0]
    combined = MultiPolygon(
        [p for k in kept for p in getattr(k, "geoms", [k])]
    )
    repaired = polygonal(valid(combined))
    return repaired if usable(repaired) else geometry
