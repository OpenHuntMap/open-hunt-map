#!/usr/bin/env python3
"""Build the Ontario Sunday gun hunting overlay from O. Reg. 663/98 Part 7.

Sunday gun hunting is permitted everywhere north of the French and Mattawa
rivers. South of them it is permitted only in the municipalities scheduled in
Part 7, so a southern municipality absent from that schedule is a prohibition,
not a gap. Ontario publishes the list and a picture of the map but no geometry,
so the schedule is joined by name onto municipal and geographic township
boundaries we already carry.

The schedule names three kinds of area and they resolve differently:
  "Armour, Township of"                     -> a lower or single tier municipality
  "Renfrew, County of"                      -> every municipality in that upper tier
  "Blair, ... Geographic Townships of"      -> survey townships, which are not
                                               municipalities and only exist in
                                               the township fabric

Reads data/on/rules/reg663.json plus the municipality and township overlays.
Writes data/on/overlays/sunday_gun.geojson.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[2]
RULES = ROOT / "data/on/rules/reg663.json"
MUNI = ROOT / "data/on/overlays/municipalities.geojson"
TWP = ROOT / "data/on/overlays/townships.geojson"
NORTH = ROOT / "data/on/overlays/sunday_gun_north.geojson"
OUT = ROOT / "data/on/overlays/sunday_gun.geojson"

# "Armour, Township of" -> ("Armour", "Township")
SUFFIX = re.compile(
    r"^(?P<names>.+?),\s*(?P<kind>Geographic Townships?|United Townships?|"
    r"Township|Town|City|Municipality|Village|County|United Counties|Country)\s+of"
    r"(?P<rest>\b.*)?$",
    re.I,
)
UPPER_KINDS = {"county", "united counties", "country"}
TOWNSHIP_KINDS = {"geographic township", "geographic townships",
                  "united township", "united townships"}
# Only a plural township entry is a list of several areas. A singular entry is
# one name that may itself contain "and", as Leeds and the Thousand Islands does.
LIST_KINDS = {"geographic townships", "united townships"}

# The schedule still uses names from before municipal restructuring, and one
# survey township is spelled differently in the regulation than in the survey
# fabric. Each alias below is a rename of the same area, not a judgement about
# which areas the schedule covers.
ALIASES = {
    # Amalgamated into Trent Lakes in 2016; the schedule kept the old name.
    "GALWAY CAVENDISH AND HARVEY": "TRENT LAKES",
    # Renamed Cavan Monaghan in 2006.
    "CAVAN MILLBROOK NORTH MONAGHAN": "CAVAN MONAGHAN",
    # Regulation spells the survey township Henvy; LIO spells it Henvey.
    "HENVY": "HENVEY",
}


def normalize(value: str) -> str:
    """Fold case, punctuation and articles so regulation and LIO names meet."""
    text = (value or "").upper()
    text = text.replace("’", "'").replace("`", "'")
    text = re.sub(r"\bSAINT\b", "ST.", text)
    text = re.sub(r"\bTHE\b", " ", text)
    text = re.sub(r"[^A-Z0-9']+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def load(path: Path) -> list[dict]:
    if not path.is_file():
        print(f"Missing {path}", file=sys.stderr)
        raise SystemExit(1)
    return json.loads(path.read_text(encoding="utf-8"))["features"]


def merge_multipart(features: list[dict]) -> list[dict]:
    """LIO splits multi-part municipalities into separate features sharing one
    id. A dedup pass that keeps only the first feature for each id silently
    drops the main polygon when a small island sorts first. Merge all parts
    into one geometry per id so that downstream dedup cannot lose coverage."""
    by_id: dict[str, list[dict]] = defaultdict(list)
    props_by_id: dict[str, dict] = {}
    for f in features:
        fid = f["properties"].get("id")
        by_id[fid].append(f)
        if fid not in props_by_id:
            props_by_id[fid] = f["properties"]
    merged: list[dict] = []
    for fid, group in by_id.items():
        if len(group) == 1:
            merged.append(group[0])
        else:
            geoms = [shape(f["geometry"]) for f in group]
            unified = unary_union(geoms)
            merged.append({
                "type": "Feature",
                "properties": props_by_id[fid],
                "geometry": mapping(unified),
            })
    return merged


def parse_entry(raw: str) -> tuple[list[str], str, str]:
    """Split a schedule entry into member names, kind, and any trailing except."""
    match = SUFFIX.match(raw.strip())
    if not match:
        # "Norfolk County", "Kawartha Lakes, City of" handled above; anything
        # else is taken as a bare municipal name.
        return [re.sub(r"\bCounty\b", "", raw, flags=re.I).strip()], "bare", ""
    kind = match.group("kind").lower()
    rest = (match.group("rest") or "").strip(" ,")
    names = match.group("names")
    if kind in LIST_KINDS:
        # "Dysart, Dudley, ... Havelock, Eyre and Clyde" is a list of townships.
        parts = [p.strip() for p in re.split(r",|\band\b", names) if p.strip()]
    else:
        parts = [names.strip()]
    return parts, kind, rest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    rules = json.loads(RULES.read_text(encoding="utf-8"))
    entries = rules["part7"]["municipalities"]
    print(f"Schedule entries: {len(entries)}")

    municipalities = merge_multipart(load(MUNI))
    townships = merge_multipart(load(TWP))
    print(f"Municipality features (after merging multi-part): {len(municipalities)}")
    print(f"Township features (after merging multi-part): {len(townships)}")

    # Municipal names arrive as "Township of Armour"; index on the bare name.
    by_muni: dict[str, list[dict]] = {}
    by_upper: dict[str, list[dict]] = {}
    for feature in municipalities:
        props = feature["properties"]
        bare = re.sub(
            r"^(TOWNSHIP|TOWN|CITY|MUNICIPALITY|VILLAGE|COUNTY|UNITED COUNTIES)\s+OF\s+",
            "",
            normalize(props.get("name")),
        )
        by_muni.setdefault(bare, []).append(feature)
        upper = re.sub(
            r"^(COUNTY|UNITED COUNTIES|REGIONAL MUNICIPALITY|DISTRICT|"
            r"DISTRICT MUNICIPALITY)\s+OF\s+",
            "",
            normalize(props.get("upper_tier")),
        )
        if upper:
            by_upper.setdefault(upper, []).append(feature)

    by_twp: dict[str, list[dict]] = {}
    for feature in townships:
        by_twp.setdefault(normalize(feature["properties"].get("name")), []).append(
            feature
        )

    out: list[dict] = []
    unmatched: list[str] = []
    seen: set[str] = set()

    for entry in entries:
        raw = entry["municipality"]
        area = entry["geographic_area"]
        names, kind, exception = parse_entry(raw)

        matches: list[tuple[dict, str]] = []
        for name in names:
            key = normalize(name)
            key = ALIASES.get(key, key)
            # A single tier county may be recorded either as "Brant" or
            # "Norfolk County", so try the name with and without the word.
            keys = [key, f"{key} COUNTY", re.sub(r"\s*COUNTY$", "", key)]
            keys = [k for i, k in enumerate(keys) if k and k not in keys[:i]]

            def first(index: dict[str, list[dict]]) -> list[dict]:
                for candidate in keys:
                    if candidate in index:
                        return index[candidate]
                return []

            if kind in TOWNSHIP_KINDS:
                pool = first(by_twp) or first(by_muni)
                kind_label = "geographic_township"
            elif kind in UPPER_KINDS:
                pool = first(by_upper) or first(by_muni)
                kind_label = "upper_tier"
            else:
                pool = first(by_muni) or first(by_twp)
                kind_label = "municipality"
            if not pool:
                unmatched.append(f"{raw}  [{kind}: {name}]")
                continue
            for feature in pool:
                matches.append((feature, kind_label))

        for feature, kind_label in matches:
            props = feature["properties"]
            identifier = f"on-sunday-{props.get('id')}"
            if identifier in seen:
                continue
            seen.add(identifier)
            properties: dict[str, object] = {
                "id": identifier,
                "name": props.get("name") or raw,
                "listed_as": raw,
                "geographic_area": area,
                "jurisdiction": kind_label,
                "sunday_gun": True,
                "basis": "reg663_part7",
            }
            if exception:
                properties["exception"] = exception
            out.append(
                {
                    "type": "Feature",
                    "properties": properties,
                    "geometry": feature["geometry"],
                }
            )

    print(f"Matched {len(out)} polygons from {len(entries)} entries")
    if unmatched:
        print(f"UNMATCHED ({len(unmatched)}):")
        for item in unmatched:
            print("   ", item)

    # Append the north-of-divide features produced by build_sunday_divide_on.py.
    # These cover the area north of the French and Mattawa rivers, where
    # O. Reg. 665/98 s. 66(1) does not prohibit Sunday gun hunting.
    # A missing divide is a build failure rather than a note. The layer would
    # still assemble and still look complete, while every point north of the
    # rivers lost its covering feature — and the card reads that absence as a
    # prohibition, so a silent skip here turns permitted country into an offence.
    if not NORTH.is_file():
        raise SystemExit(
            f"Missing {NORTH}. Run build_sunday_divide_on.py first: without it "
            "everything north of the French and Mattawa rivers would be "
            "reported as prohibited."
        )
    north_data = json.loads(NORTH.read_text(encoding="utf-8"))
    north_features = north_data.get("features", [])
    out.extend(north_features)
    print(f"Appended {len(north_features)} north-of-divide features")

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "layer": "sunday_gun",
            "province": "on",
            "feature_count": len(out),
            "coverage": (
                "Municipalities and geographic townships south of the French and "
                "Mattawa rivers where Sunday gun hunting is permitted"
            ),
            "license": "OGL-Ontario",
            "license_url": (
                "https://www.ontario.ca/page/open-government-licence-ontario"
            ),
            "source": rules["source"],
            "citation": f"{rules['citation']}, Part 7, Schedule 1",
            "currency_date": rules["currency_date"],
            "rule": rules["part7"]["section"],
            "note": (
                "North of the French and Mattawa rivers Sunday gun hunting is "
                "permitted and no polygon is drawn. South of those rivers it is "
                "permitted only inside these boundaries. Ontario publishes the "
                "list of municipalities but not its geometry, so these outlines "
                "are municipal and survey township boundaries matched to the "
                "schedule by name."
            ),
            "unmatched_entries": unmatched,
        },
        "features": out,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {args.out} ({args.out.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
