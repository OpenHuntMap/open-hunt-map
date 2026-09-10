"""Shared geometry thinning for overlay builds.

Pack size is a hard constraint, so overlays are simplified. Done naively that
silently deletes features, and a deleted feature is a wrong answer: dropping a
municipality loses a bylaw jurisdiction, and dropping a narrow waterway park
loses somewhere hunting is actually permitted. The rules here keep the feature
and spend the savings on detail nobody needs instead.
"""

from __future__ import annotations

from shapely.geometry import MultiPolygon, Polygon
from shapely.validation import make_valid

# Roughly one hectare in square degrees at Ontario latitudes. Simplification
# cannot take a ring below four points, so shorelines made of thousands of bare
# rocks and lakes stay huge however hard they are simplified. Discarding the
# parts too small to read on a map is the only real saving available.
MIN_PART_AREA = 1e-6


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
    return MultiPolygon([p for k in kept for p in getattr(k, "geoms", [k])])
