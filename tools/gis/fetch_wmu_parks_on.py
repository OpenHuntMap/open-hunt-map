#!/usr/bin/env python3
"""Fetch Ontario WMU + provincial parks GeoJSON extracts (OGL-Ontario).

Parks carry their hunting permission from O. Reg. 663/98 Part 3 rather than from
LIO, which does not publish one. Hunting in an Ontario provincial park is
prohibited unless that park is scheduled in Part 3, so an unscheduled park is
closed. Most schedules open only a surveyed piece of a park, and that piece is
metes-and-bounds prose that cannot be mapped, so those parks are reported as
partly open with the regulation's own wording rather than as open.

Run parse_reg663_on.py first; without it the parks layer is written with the
permission unknown rather than guessed.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape

from geomutil import thin, usable, valid

ROOT = Path(__file__).resolve().parents[2]
RULES = ROOT / "data/on/rules/reg663.json"
PPCRA_RULES = ROOT / "data/on/rules/ppcra.json"
REG_URL = "https://www.ontario.ca/laws/regulation/980663"
PPCRA_URL = "https://www.ontario.ca/laws/statute/06p12"

# One park is opened in part by the Act rather than by the regulation, so a card
# assembled only from O. Reg. 663/98 Part 3 quotes Schedule 42 — the McRae
# Addition in Eyre Township — and tells a hunter standing in Bruton or Clyde that
# Algonquin is closed to them. Keyed on the normalised park name, and read from
# data/on/rules/ppcra.json rather than written out here, so the quote the card
# shows is the statute's own wording.
STATUTORY_OPENINGS = {
    "ALGONQUIN PROVINCIAL PARK": "algonquin_bruton_clyde",
}
# ~50 m. Waterway parks are river corridors only a few hundred metres wide and
# several of them are open to hunting under Part 3, so the tolerance has to stay
# fine enough not to erase them: at 200 m French River, Mattawa River, Ottawa
# River, Lake of the Woods, LaVerendrye and Bonnechere River all disappeared.
# WMU boundaries carry no such risk.
PARK_SIMPLIFY = 0.0005
WMU_SIMPLIFY = 0.002
WMU_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open05/MapServer/5/query"
)
PARK_URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open03/MapServer/4/query"
)


def query(url: str, params: dict) -> dict:
    full = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(full, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(text[:200])
    return json.loads(text)


def fetch_all(url: str, fields: str, simplify: float) -> list[dict]:
    features: list[dict] = []
    offset = 0
    page_size = 1000
    while True:
        params = {
            "where": "1=1",
            "outFields": fields,
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson",
            "resultRecordCount": str(page_size),
            "resultOffset": str(offset),
            "maxAllowableOffset": str(simplify),
        }
        page = query(url, params)
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  {url.split('/')[-2:]} offset={offset} total={len(features)}", flush=True)
        if len(batch) < page_size:
            break
        offset += page_size
    return features


def simplify_features(raw: list[dict], tol: float) -> list[dict]:
    out = []
    dropped = 0
    for feature in raw:
        geom = feature.get("geometry")
        if not geom:
            dropped += 1
            continue
        try:
            geometry = thin(valid(shape(geom)), tol)
            if not usable(geometry):
                dropped += 1
                continue
            out.append({**feature, "geometry": mapping(geometry)})
        except Exception:  # noqa: BLE001
            dropped += 1
    if dropped:
        print(f"  dropped {dropped} feature(s) with unusable geometry")
    return out


def write_wmu(features: list[dict]) -> None:
    out_features = []
    for i, feature in enumerate(features, 1):
        props = feature.get("properties") or {}
        name = props.get("OFFICIAL_NAME") or f"WMU {i}"
        out_features.append(
            {
                "type": "Feature",
                "properties": {
                    "id": f"on-wmu-{i}",
                    "wmu_id": name,
                    "name": name,
                    "province": "ON",
                    "source": "Ontario LIO — Wildlife Management Unit",
                },
                "geometry": feature["geometry"],
            }
        )
    path = ROOT / "data/on/overlays/wmu.geojson"
    path.write_text(
        json.dumps(
            {
                "type": "FeatureCollection",
                "metadata": {
                    "crs": "EPSG:4326",
                    "layer": "wmu",
                    "feature_count": len(out_features),
                    "license": "OGL-Ontario",
                },
                "features": out_features,
            }
        ),
        encoding="utf-8",
    )
    print("WMU", len(out_features), path.stat().st_size)


# The regulation names a few parks differently from the LIO protected-area
# register. Each of these is the same park under an older or alternative name,
# checked one at a time; nothing here is a guess at which parks are open.
PARK_ALIASES = {
    # Regulated as a signature site before it was renamed a provincial park.
    "KAWARTHA HIGHLANDS PROVINCIAL PARK": "KAWARTHA HIGHLANDS SIGNATURE SITE PARK",
}


def normalize_park(value: str) -> str:
    """Fold a park name so the register and the regulation can be compared."""
    text = (value or "").upper().replace("’", "'").replace("`", "'")
    text = re.sub(r"\(([^)]*)\)", " ", text)          # drop "(RECREATIONAL CLASS)"
    text = re.sub(r"\bSAINT\b", "ST.", text)
    text = re.sub(r"[^A-Z0-9']+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def load_park_openings() -> tuple[list[dict], str]:
    if not RULES.is_file():
        print(
            f"Missing {RULES}. Run: python parse_reg663_on.py",
            file=sys.stderr,
        )
        return [], ""
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    schedules = rules["part3"]["schedules"]
    for schedule in schedules:
        schedule["_text"] = normalize_park(schedule["description"])
    return schedules, rules.get("currency_date") or ""


def load_statutory_openings() -> dict[str, dict]:
    """Section 15 openings written into the Act, keyed by normalised park name.

    Absent rules are not fatal here the way the regulation is: without them the
    card falls back to quoting only the schedule, which is incomplete but not
    wrong about the park being open in part.
    """
    if not PPCRA_RULES.is_file():
        print(
            f"Missing {PPCRA_RULES}. Run: python parse_ppcra_on.py",
            file=sys.stderr,
        )
        return {}
    rules = json.loads(PPCRA_RULES.read_text(encoding="utf-8"))
    provisions = rules["provisions"]
    currency = rules.get("currency_date") or ""
    out: dict[str, dict] = {}
    for park, key in STATUTORY_OPENINGS.items():
        entry = provisions.get(key)
        if not entry:
            print(f"  ppcra.json has no {key}; {park} keeps only its schedule")
            continue
        out[park] = {
            "statute_text": entry["text"],
            "statute_citation": (
                f"{rules['title']}, s. {entry['subsection']}"
            ),
            "statute_url": PPCRA_URL,
            "statute_currency_date": currency,
        }
    return out


def match_schedules(name: str, schedules: list[dict]) -> list[dict]:
    """Find every schedule that opens this park, by exact name only.

    Matching on a shortened stem would risk opening the wrong park, which is the
    one error this app must never make, so a park whose name does not appear
    verbatim in a schedule stays closed and is counted as a gap instead. Note
    that Bonnechere and Bonnechere River are different parks, which is exactly
    the distinction a stem match would lose.
    """
    key = normalize_park(name)
    key = PARK_ALIASES.get(key, key)
    if not key:
        return []
    hits = [s for s in schedules if key in s["_text"]]
    # A park opened in whole by one schedule is open regardless of any partial
    # schedule that also names it.
    hits.sort(key=lambda s: 0 if s["extent"] == "whole" else 1)
    return hits


def write_parks(features: list[dict]) -> None:
    schedules, currency = load_park_openings()
    statutory = load_statutory_openings()
    out_features = []
    matched: set[int] = set()
    matched_statutes: set[str] = set()
    counts = {"whole": 0, "part": 0, "closed": 0, "unknown": 0}

    for i, feature in enumerate(features, 1):
        props = feature.get("properties") or {}
        name = props.get("PROTECTED_AREA_NAME_ENG") or f"Park {i}"
        klass = props.get("PROVINCIAL_PARK_CLASS_ENG") or "Provincial Park"
        properties: dict[str, object] = {
            "id": f"on-park-{i}",
            "name": name,
            "park_type": klass,
            "designation": klass,
            "province": "ON",
            "source": "Ontario LIO — Provincial Park Regulated",
        }

        hits = match_schedules(name, schedules) if schedules else []
        if not schedules:
            properties["hunting_allowed"] = None
            properties["basis"] = "unknown"
            counts["unknown"] += 1
        elif not hits:
            properties["hunting_allowed"] = False
            properties["basis"] = "reg663_part3_unlisted"
            counts["closed"] += 1
        else:
            schedule = hits[0]
            matched.update(s["schedule"] for s in hits)
            properties["reg_schedule"] = schedule["schedule"]
            if len(hits) > 1:
                properties["reg_schedules"] = sorted(s["schedule"] for s in hits)
            properties["hunting_extent"] = schedule["extent"]
            if schedule["extent"] == "whole":
                properties["hunting_allowed"] = True
                properties["basis"] = "reg663_part3"
                counts["whole"] += 1
            else:
                # The open piece is described in words, not mapped, so this
                # boundary cannot say whether a given point is inside it.
                properties["hunting_allowed"] = None
                properties["basis"] = "reg663_part3_partial"
                counts["part"] += 1
            if schedule["conditional"] or len(schedule["description"]) <= 400:
                properties["reg_text"] = schedule["description"]

        # Applied whatever the schedules said, and after them, because the Act
        # opens this ground regardless of the regulation. It never makes a park
        # more closed, so a park already open in whole keeps that answer.
        if opening := statutory.get(normalize_park(name)):
            properties.update(opening)
            matched_statutes.add(normalize_park(name))
            if properties.get("hunting_allowed") is False:
                # The Act opens part of a park the schedules do not reach, so the
                # answer stops being a flat no and becomes the partial one.
                properties["hunting_allowed"] = None
                properties["basis"] = "ppcra_s15_2_partial"
                properties["hunting_extent"] = "part"
                counts["closed"] -= 1
                counts["part"] += 1
        out_features.append(
            {
                "type": "Feature",
                "properties": properties,
                "geometry": feature["geometry"],
            }
        )

    unmatched = sorted({s["schedule"] for s in schedules} - matched)
    print(
        f"parks: {counts['whole']} open, {counts['part']} partly open, "
        f"{counts['closed']} closed, {counts['unknown']} unknown"
    )
    if unmatched:
        print(
            f"  {len(unmatched)} Part 3 schedules did not bind to a park polygon "
            f"(those areas stay reported as closed): {unmatched}"
        )
    unbound_statutes = sorted(set(statutory) - matched_statutes)
    if unbound_statutes:
        print(
            "  WARNING: a statutory opening did not bind to a park polygon, so "
            f"the card will not report it: {unbound_statutes}",
            file=sys.stderr,
        )

    path = ROOT / "data/on/overlays/parks.geojson"
    path.write_text(
        json.dumps(
            {
                "type": "FeatureCollection",
                "metadata": {
                    "crs": "EPSG:4326",
                    "layer": "parks",
                    "feature_count": len(out_features),
                    "license": "OGL-Ontario",
                    "hunting_source": (
                        "O. Reg. 663/98 (Area Descriptions) Part 3 under the Fish "
                        "and Wildlife Conservation Act, 1997"
                    ),
                    "hunting_source_url": REG_URL,
                    "hunting_currency_date": currency,
                            "unbound_schedules": unmatched,
                            "extent_note": (
                                "The regulation opens only a described part of "
                                "this park. Ontario publishes that description "
                                "in words, not as a boundary, so this outline "
                                "cannot tell you whether your spot is inside it."
                            ),
                    "note": (
                        "Hunting in an Ontario provincial park is prohibited unless "
                        "the park is scheduled in O. Reg. 663/98 Part 3. Where a "
                        "schedule opens only a surveyed part of a park, the "
                        "regulation describes that part in words and Ontario does "
                        "not publish its boundary, so the park is reported as partly "
                        "open and this outline cannot tell you whether a particular "
                        "point is inside the open area."
                    ),
                },
                "features": out_features,
            }
        ),
        encoding="utf-8",
    )
    print("parks", len(out_features), path.stat().st_size)


def main() -> int:
    print("Fetching WMUs...")
    wmu = simplify_features(
        fetch_all(WMU_URL, "OFFICIAL_NAME", WMU_SIMPLIFY), WMU_SIMPLIFY
    )
    write_wmu(wmu)
    print("Fetching parks...")
    raw = fetch_all(
        PARK_URL,
        "PROTECTED_AREA_NAME_ENG,PROVINCIAL_PARK_CLASS_ENG",
        PARK_SIMPLIFY,
    )
    parks = simplify_features(raw, PARK_SIMPLIFY)
    if len(parks) != len(raw):
        print(
            f"  WARNING: {len(raw) - len(parks)} of {len(raw)} parks lost; "
            "a park that disappears is somewhere the app cannot report a closure",
            file=sys.stderr,
        )
    write_parks(parks)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
