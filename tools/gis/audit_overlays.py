#!/usr/bin/env python3
"""Refuse to publish overlays that are broken in ways we have already shipped.

Every check here exists because the thing it checks for actually happened, and
in each case the build scripts produced it from sound upstream data rather than
inheriting it. That is the reason this runs in CI instead of living in a notebook:
a monthly rebuild can reintroduce any of these and hand it to someone deciding
whether it is legal to fire a rifle.

  validity     Two features reached the pack as invalid polygons, because a
               rounding step ran after the validity repair instead of before it.
               Shapely's own predicates are unreliable on an invalid ring, so an
               invalid parcel is not a cosmetic defect: the point-in-polygon test
               the Land Info card depends on may simply answer wrongly.

  divide       1,015 slivers along the French and Mattawa rivers were covered by
               neither the north polygon nor the uncertainty band, because the
               divide was cut before it was simplified and the two pieces stopped
               meeting. The card reads no covering feature as a prohibition, so
               every sliver was a false "not permitted" in country where Sunday
               gun hunting is legal.

  licensing    AGENTS.md requires source, license and license_url on every layer.
               Nothing enforced it, and an unattributed layer is a licence breach
               rather than a missing field.

  answers      Known coordinates whose answers were checked by hand against the
               ministry's own published list and, for the first two, on a phone.
               These are the regression net: they would have caught the multipart
               Sunday gun bug and the missing county forest tracts.

Usage:
    python tools/gis/audit_overlays.py            # every enabled province
    python tools/gis/audit_overlays.py --province on
    python tools/gis/audit_overlays.py --skip-divide   # faster, less thorough

Exits non-zero on any failure, and says which check failed and where.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from shapely.geometry import Point, shape
from shapely.ops import unary_union
from shapely.strtree import STRtree
from shapely.validation import explain_validity, make_valid

ROOT = Path(__file__).resolve().parents[2]

# Layer metadata quotes its sources, so the output carries accented French and
# em dashes. A Windows console defaults to cp1252 and raises on them, which would
# turn "your data is fine" into a crash traceback for anyone running this by hand.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):  # already wrapped, or not a tty
        pass

# About 1.1 km, roughly two band widths, so a gap wide enough to stand in cannot
# hide between samples.
DIVIDE_STEP_DEG = 0.01

# Coordinates whose answers are known, and what has to still be true of them.
#
# Each expectation names a layer and the property values that layer must report
# there. Deliberately few and deliberately specific: this is a net for the
# failures we have actually seen, not a substitute for reading the sources.
KNOWN_ANSWERS: dict[str, list[tuple[str, float, float, str, dict[str, object]]]] = {
    "on": [
        # Checked on a phone against iHunter, which was right and we were not:
        # this point had no Crown land answer at all until the CLUPA join was
        # rebuilt.
        (
            "Round Lake Crown land",
            45.73552,
            -77.38371,
            "crown_land",
            {"policy_id": "G396"},
        ),
        (
            "Round Lake is in a scheduled municipality",
            45.73552,
            -77.38371,
            "sunday_gun",
            {"basis": "reg663_part7"},
        ),
        # Renfrew County's tracts were absent entirely, which is what sent us
        # looking at the Agreement Forest source in the first place.
        (
            "Indian River Tract",
            45.751196,
            -77.346804,
            "municipal_forest",
            {},
        ),
        # Ottawa is a single-tier municipality named in the schedule. It read as
        # prohibited while the schedule lookup took only the first of several
        # covering features.
        (
            "Ottawa is scheduled",
            45.37166,
            -75.79503,
            "sunday_gun",
            {"basis": "reg663_part7"},
        ),
        # On the Ottawa River at Mattawa, inside the uncertainty band. The card
        # must say it cannot tell which bank you are on rather than claiming
        # permission, so this must not resolve to the clear north polygon.
        (
            "Mattawa is too close to the divide to say",
            46.32,
            -78.70,
            "sunday_gun",
            {"near_divide": True},
        ),
    ],
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def enabled_provinces() -> list[str]:
    provinces = load(ROOT / "data" / "provinces.json")["provinces"]
    return [p["id"] for p in provinces if p.get("enabled")]


def overlay_paths(province: str) -> list[Path]:
    return sorted((ROOT / "data" / province / "overlays").glob("*.geojson"))


def check_validity(province: str, failures: list[str]) -> None:
    """Every geometry is valid and non-empty."""
    for path in overlay_paths(province):
        payload = load(path)
        bad = 0
        for index, feature in enumerate(payload.get("features") or []):
            geometry = feature.get("geometry")
            name = (feature.get("properties") or {}).get("id") or f"index {index}"
            if not geometry:
                failures.append(f"{path.name}: {name} has no geometry")
                continue
            candidate = shape(geometry)
            if candidate.is_empty:
                failures.append(f"{path.name}: {name} is empty")
            elif not candidate.is_valid:
                bad += 1
                if bad <= 5:
                    failures.append(
                        f"{path.name}: {name} is invalid — "
                        f"{explain_validity(candidate)}"
                    )
        if bad > 5:
            failures.append(f"{path.name}: and {bad - 5} more invalid features")


def check_licensing(province: str, failures: list[str]) -> None:
    """Every layer that carries data names its source and licence.

    Scoped to layers with features, because Quebec ships two deliberately empty
    ones — there is no province-wide municipal forest layer and its survey cantons
    are not used — and demanding attribution for nothing would only invite
    somebody to fill the field in with something untrue. An empty layer owes an
    explanation instead, which is a different requirement and checked as one.
    """
    for path in overlay_paths(province):
        payload = load(path)
        metadata = payload.get("metadata") or {}
        if not (payload.get("features") or []):
            if not str(metadata.get("coverage") or metadata.get("note") or "").strip():
                failures.append(
                    f"{path.name}: has no features and does not say why"
                )
            continue
        for key in ("source", "license"):
            if not str(metadata.get(key) or "").strip():
                failures.append(f"{path.name}: metadata is missing {key}")
        if not str(metadata.get("license_url") or "").strip():
            # A licence we cannot cite is allowed through only if it says so and
            # says why. Quebec's hunting zones are the live case: the service
            # publishes a copyright line and names no licence. Guessing CC-BY
            # because sibling datasets use it would be asserting a permission
            # nobody granted, and a silent blank would let it be forgotten — so
            # the gap has to be written down, and it prints on every run.
            excuse = str(metadata.get("license_unconfirmed") or "").strip()
            if excuse:
                print(f"  UNCONFIRMED LICENCE {path.name}: {excuse}")
            else:
                failures.append(f"{path.name}: metadata is missing license_url")


def check_divide(province: str, failures: list[str]) -> None:
    """No point near the French and Mattawa rivers is left without an answer.

    Scoped to the ground our own divide geometry claims, because outside it the
    answer belongs to the schedule of municipalities and its absence means
    prohibited rather than unknown.
    """
    directory = ROOT / "data" / province / "overlays"
    layer = directory / "sunday_gun.geojson"
    north_file = directory / "sunday_gun_north.geojson"
    if not layer.is_file() or not north_file.is_file():
        # Only Ontario has one, and a province without it is not at fault.
        return

    geometries = []
    properties = []
    for feature in load(layer).get("features") or []:
        geometries.append(make_valid(shape(feature["geometry"])))
        properties.append(feature.get("properties") or {})
    index = STRtree(geometries)

    by_id = {
        (f.get("properties") or {}).get("id"): f
        for f in load(north_file).get("features") or []
    }
    try:
        band = make_valid(shape(by_id["on-sunday-divide-band"]["geometry"]))
        north = make_valid(shape(by_id["on-sunday-north"]["geometry"]))
    except (KeyError, TypeError):
        failures.append(
            f"{north_file.name}: expected features on-sunday-divide-band and "
            "on-sunday-north; without both, everything north of the rivers "
            "loses its answer and the card reads that as a prohibition"
        )
        return

    ours = unary_union([band, north])
    minx, miny, maxx, maxy = band.bounds
    holes: list[tuple[float, float]] = []
    sampled = 0

    y = miny
    while y <= maxy:
        x = minx
        while x <= maxx:
            point = Point(x, y)
            if ours.covers(point):
                sampled += 1
                covered = any(
                    geometries[i].covers(point) for i in index.query(point)
                )
                if not covered:
                    holes.append((round(y, 5), round(x, 5)))
            x += DIVIDE_STEP_DEG
        y += DIVIDE_STEP_DEG

    if not sampled:
        failures.append(
            f"{layer.name}: the divide corridor sampled no points at all, which "
            "means the band geometry is not where this check expects it"
        )
    if holes:
        shown = ", ".join(f"{lat},{lon}" for lat, lon in holes[:6])
        failures.append(
            f"{layer.name}: {len(holes)} of {sampled} points near the divide are "
            f"covered by no feature, so each reads as a Sunday gun prohibition "
            f"where hunting is legal — e.g. {shown}"
        )
    else:
        print(f"  divide: {sampled} points near the divide, none without an answer")


def check_known_answers(province: str, failures: list[str]) -> None:
    """Coordinates whose answers were verified by hand still answer that way."""
    expectations = KNOWN_ANSWERS.get(province) or []
    if not expectations:
        return
    cache: dict[str, tuple[STRtree, list[dict]]] = {}

    for label, latitude, longitude, layer, expected in expectations:
        path = ROOT / "data" / province / "overlays" / f"{layer}.geojson"
        if not path.is_file():
            failures.append(f"{label}: {layer}.geojson is missing")
            continue
        if layer not in cache:
            geometries = []
            properties = []
            for feature in load(path).get("features") or []:
                if feature.get("geometry"):
                    geometries.append(make_valid(shape(feature["geometry"])))
                    properties.append(feature.get("properties") or {})
            cache[layer] = (STRtree(geometries), properties, geometries)

        index, properties, geometries = cache[layer]
        point = Point(longitude, latitude)
        hits = [
            properties[i] for i in index.query(point) if geometries[i].covers(point)
        ]
        if not hits:
            failures.append(
                f"{label}: no {layer} feature covers {latitude}, {longitude}"
            )
            continue
        for key, want in expected.items():
            if not any(hit.get(key) == want for hit in hits):
                got = sorted({repr(hit.get(key)) for hit in hits})
                failures.append(
                    f"{label}: expected {layer}.{key} == {want!r} at "
                    f"{latitude}, {longitude}; got {', '.join(got)}"
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--province", default="all")
    parser.add_argument(
        "--skip-divide",
        action="store_true",
        help="skip the corridor walk, which is the slowest check",
    )
    args = parser.parse_args()

    provinces = (
        enabled_provinces() if args.province == "all" else [args.province]
    )
    failures: list[str] = []

    for province in provinces:
        directory = ROOT / "data" / province / "overlays"
        if not directory.is_dir():
            failures.append(f"{province}: no overlays directory")
            continue
        print(f"AUDIT {province.upper()} — {len(overlay_paths(province))} layers")
        check_validity(province, failures)
        check_licensing(province, failures)
        check_known_answers(province, failures)
        if not args.skip_divide:
            check_divide(province, failures)

    if failures:
        print(f"\n{len(failures)} problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
