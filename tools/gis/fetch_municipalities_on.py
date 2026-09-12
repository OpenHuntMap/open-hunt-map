#!/usr/bin/env python3
"""Fetch Ontario lower/single-tier municipal boundaries (OGL-Ontario).

These are the governments that pass local bylaws (firearm discharge, etc.).
Geographic survey townships are different and are NOT used for bylaw lookup.

  python fetch_municipalities_on.py --out ../../data/on/overlays/municipalities.geojson
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from shapely.geometry import MultiPolygon, Polygon, shape
    from shapely.validation import make_valid
except ImportError:
    print("pip install -r requirements.txt", file=sys.stderr)
    raise

from geomutil import polygonal, quantized_valid, usable, valid

LAYER_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open03/MapServer/14/query"
)
OUT_FIELDS = (
    "OGF_ID,MUNICIPAL_NAME,MUNICIPAL_TYPE,MUNICIPAL_NAME_PREFIX,"
    "UPPER_TIER_MUNICIPALITY,MUNID"
)
# Asking for full-resolution geometry makes the service answer with an HTML
# error page rather than JSON, even 50 features at a time. Asking it to simplify
# is answerable but returns empty geometry for the smallest municipalities, and
# each of those is still a bylaw jurisdiction. So the whole layer is paged with
# simplification and the empties are then re-requested one at a time.
PAGE_SIZE = 200
SIMPLIFY_DEGREES = 0.001


def _query(params: dict) -> dict:
    url = f"{LAYER_URL}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(f"Non-JSON: {text[:160]!r}")
    return json.loads(text)


def _has_geometry(feature: dict) -> bool:
    """True only if the geometry survives parsing as a usable polygon.

    Simplified small municipalities come back with coordinates that collapse to
    an empty or non-polygonal shape, so presence of coordinates is not enough.
    """
    geometry = feature.get("geometry") or {}
    if not geometry.get("coordinates"):
        return False
    try:
        parsed = shape(geometry)
        if not parsed.is_valid:
            parsed = make_valid(parsed)
    except Exception:  # noqa: BLE001
        return False
    return not parsed.is_empty and parsed.geom_type in {"Polygon", "MultiPolygon"}


def fetch_all() -> list[dict]:
    features: list[dict] = []
    offset = 0
    while True:
        page = _query(
            {
                "where": "1=1",
                "outFields": OUT_FIELDS,
                "returnGeometry": "true",
                "outSR": "4326",
                "f": "geojson",
                "resultRecordCount": str(PAGE_SIZE),
                "resultOffset": str(offset),
                "maxAllowableOffset": str(SIMPLIFY_DEGREES),
            }
        )
        batch = page.get("features") or []
        features.extend(batch)
        print(f"fetched {len(features)}", flush=True)
        if len(batch) < PAGE_SIZE:
            break
        offset += PAGE_SIZE

    missing = [f for f in features if not _has_geometry(f)]
    if missing:
        print(f"Re-requesting {len(missing)} municipalities at full resolution …",
              flush=True)
        recovered = 0
        for feature in missing:
            identifier = (feature.get("properties") or {}).get("OGF_ID")
            if identifier is None:
                continue
            page = None
            for attempt in range(3):
                try:
                    page = _query(
                        {
                            "where": f"OGF_ID = {int(identifier)}",
                            "outFields": OUT_FIELDS,
                            "returnGeometry": "true",
                            "outSR": "4326",
                            "f": "geojson",
                        }
                    )
                    break
                except Exception as error:  # noqa: BLE001
                    if attempt == 2:
                        print(f"  OGF_ID {identifier}: {error}", file=sys.stderr)
                    else:
                        time.sleep(2 * (attempt + 1))
            if page is None:
                continue
            for candidate in page.get("features") or []:
                if _has_geometry(candidate):
                    feature["geometry"] = candidate["geometry"]
                    recovered += 1
                    break
        print(f"  recovered {recovered}/{len(missing)}", flush=True)
    return features


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


def display_name(props: dict) -> str:
    name = (props.get("MUNICIPAL_NAME") or "").strip()
    prefix = (props.get("MUNICIPAL_NAME_PREFIX") or "").strip()
    upper = name.upper()
    if upper.startswith(TITLES):
        raw = name
    elif prefix and not upper.startswith(prefix.upper()):
        raw = f"{prefix} {name}".strip()
    else:
        # MUNICIPAL_TYPE is a classification such as "Single Tier Municipality",
        # not a name component, so names like "Norfolk County" stand alone.
        raw = name or "Unknown municipality"
    for title in TITLES:
        while raw.upper().startswith(title + title):
            raw = raw[len(title):]
    return raw.title().replace(" Of ", " of ").replace(" And ", " and ")


# Roughly one hectare in square degrees at Ontario latitudes. Island-heavy
# municipalities such as The Archipelago and Killarney are made of thousands of
# bare rocks; simplification cannot take a polygon below four points, so the
# only way to keep this overlay a sensible size is to drop the parts too small
# to matter for a bylaw lookup. The largest part is always kept.
MIN_PART_AREA = 1e-6


def _drop_small_holes(part):
    """Remove negligible interior rings.

    Simplification cannot take a ring below four points, so a municipality full
    of small lakes keeps every one of them: Killarney's outline is a single
    polygon carrying over twenty thousand vertices almost entirely in holes.
    """
    if part.geom_type != "Polygon" or not part.interiors:
        return part
    holes = [
        ring for ring in part.interiors
        if Polygon(ring).area >= MIN_PART_AREA
    ]
    if len(holes) == len(part.interiors):
        return part
    rebuilt = Polygon(part.exterior, holes)
    return rebuilt if rebuilt.is_valid else make_valid(rebuilt)


def thin(geometry, tolerance: float):
    """Simplify part by part and drop islands and lakes too small to matter."""
    parts = list(getattr(geometry, "geoms", [geometry]))
    kept = []
    for part in parts:
        if part.area < MIN_PART_AREA:
            continue
        thinned = _drop_small_holes(part).simplify(tolerance, preserve_topology=True)
        if not thinned.is_empty and thinned.geom_type in {"Polygon", "MultiPolygon"}:
            kept.append(thinned)
    if not kept:
        # Every part was tiny or collapsed: keep the largest so the jurisdiction
        # still exists on the map.
        largest = max(parts, key=lambda part: part.area)
        thinned = largest.simplify(tolerance, preserve_topology=True)
        return largest if thinned.is_empty else thinned
    combined = kept[0] if len(kept) == 1 else MultiPolygon(
        [p for k in kept for p in getattr(k, "geoms", [k])]
    )
    repaired = polygonal(valid(combined))
    return repaired if usable(repaired) else geometry


def normalize(features: list[dict], simplify: float) -> list[dict]:
    out = []
    for i, feature in enumerate(features, 1):
        props = feature.get("properties") or {}
        geom = feature.get("geometry")
        if not geom:
            continue
        try:
            geometry = shape(geom)
            if not geometry.is_valid:
                geometry = make_valid(geometry)
            if simplify > 0:
                geometry = thin(geometry, simplify)
            if geometry.is_empty or geometry.geom_type not in {
                "Polygon",
                "MultiPolygon",
            }:
                print(f"skip {i}: empty geometry", file=sys.stderr)
                continue
        except Exception as exc:  # noqa: BLE001
            print(f"skip {i}: {exc}", file=sys.stderr)
            continue
        name = display_name(props)
        output_geometry = quantized_valid(geometry, label=name)
        out.append(
            {
                "type": "Feature",
                "properties": {
                    "id": props.get("MUNID") or f"on-mun-{i}",
                    "name": name,
                    "municipal_type": props.get("MUNICIPAL_TYPE") or "",
                    "upper_tier": props.get("UPPER_TIER_MUNICIPALITY") or "",
                    "type": "municipality",
                    "province": "ON",
                    "source": "Ontario LIO — Municipal Boundary Lower and Single Tier",
                },
                "geometry": output_geometry,
            }
        )
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # ~200 m. These boundaries answer "which council's bylaws apply here", so
    # shoreline detail is not worth the pack size; Killarney alone carries 26,000
    # vertices of Georgian Bay coast at full resolution.
    parser.add_argument("--simplify", type=float, default=0.002)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2]
        / "data"
        / "on"
        / "overlays"
        / "municipalities.geojson",
    )
    args = parser.parse_args()
    print("Fetching all Ontario lower/single-tier municipalities...")
    raw = fetch_all()
    features = normalize(raw, args.simplify)
    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "municipalities",
            "feature_count": len(features),
            "source": "Ontario LIO - Municipal Boundary Lower and Single Tier",
            "source_url": LAYER_URL,
            "license": "OGL-Ontario",
            "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
            "note": "Use for local bylaw jurisdiction (not geographic survey townships).",
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} -> {args.out} ({args.out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
