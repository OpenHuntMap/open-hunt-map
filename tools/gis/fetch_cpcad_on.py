#!/usr/bin/env python3
"""Build the two ON layers that come from ECCC's CPCAD: CA land and federal closures.

Both are land a hunter would plausibly try and neither is huntable on a
provincial licence alone, so their absence was a hole in the app rather than a
missing nicety.

conservation_authority
    409 Ontario properties owned or managed by conservation authorities. This
    land looks and behaves like public land, often sits next to municipal forest
    we already draw as open, and is in fact permit-only: authorities charge a
    fee, several allocate popular tracts by lottery, and some properties are
    closed to hunting outright. Hunting one without its authority's permit is
    trespass.

    CPCAD holds only what each authority chose to report, so coverage is
    genuinely partial -- Grand River CA is absent entirely. The layer therefore
    adds uncertainty and never removes it: a polygon means "ask this authority",
    and no polygon means nothing at all. That is recorded in the metadata so the
    card can say it rather than implying completeness.

federal_closure
    National Wildlife Areas and Migratory Bird Sanctuaries. The prohibitions
    come from the regulations, not from CPCAD, and are read by
    parse_federal_wildlife_regs.py so the app quotes the law rather than us:

      NWA   Hunting and possessing hunting equipment are prohibited in every
            wildlife area. Only Schedule I.1 can open one, and in Ontario it
            opens sport hunting of waterfowl in Big Creek and Long Point alone
            -- in designated areas the Minister sets and does not publish, so
            even those two cannot be reported as simply open.
      MBS   Hunting migratory birds is prohibited, and separately possessing any
            firearm or hunting appliance is prohibited. The second is what makes
            a sanctuary closed to hunting anything by any means, and it is the
            one a deer hunter walking through would not expect.

    A CPCAD polygon whose name is not in the current schedule is reported as an
    unverified closure rather than either asserted or dropped.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape

from geomutil import thin, usable, valid

ROOT = Path(__file__).resolve().parents[2]
RULES = ROOT / "data/on/rules/federal_wildlife.json"
CA_OUT = ROOT / "data/on/overlays/conservation_authority.geojson"
FED_OUT = ROOT / "data/on/overlays/federal_closure.geojson"

SERVICE = (
    "https://maps-cartes.ec.gc.ca/arcgis/rest/services/CWS_SCF/CPCAD/"
    "MapServer/0/query"
)
# CPCAD codes location as an integer; 9 is Ontario.
ONTARIO = 9
SOURCE = "Canadian Protected and Conserved Areas Database (CPCAD), ECCC"
SOURCE_URL = (
    "https://www.canada.ca/en/environment-climate-change/services/"
    "national-wildlife-areas/protected-conserved-areas-database.html"
)
LICENSE = "Open Government Licence – Canada"
LICENSE_URL = "https://open.canada.ca/en/open-government-licence-canada"

FIELDS = "NAME_E,TYPE_E,OWNER_E,MGMT_E,O_AREA_HA,MECH_E,MPLAN_REF,ESTYEAR"
PAGE_SIZE = 60

# CA properties are small southern parcels, so the tolerance stays fine and the
# minimum part is well under a hectare: unlike a municipality, a two-hectare
# tract here is the whole property.
CA_SIMPLIFY = 0.0001
CA_MIN_PART = 1e-9
FED_SIMPLIFY = 0.0001
FED_MIN_PART = 1e-9

# A conservation authority is the body that issues the permit, so recognising it
# decides who the card tells you to ask. Two authorities dropped "Authority"
# from their branding and are named here rather than pattern-matched.
AUTHORITY_ALIASES = {"SOUTH NATION CONSERVATION", "CONSERVATION SUDBURY"}

BASIS = {
    "ca_permit": (
        "Conservation authority land. Hunting here needs a permit from the "
        "authority on top of your provincial licence. Several authorities "
        "allocate their properties by lottery, charge a fee, or close some "
        "tracts to hunting entirely. Being on the map is not permission."
    ),
    "conservation_permission": (
        "Reported as a conserved area but managed by a municipality or other "
        "body rather than a conservation authority. Hunting needs that owner's "
        "permission, and local firearm discharge bylaws may apply as well."
    ),
    "nwa_closed": (
        "National Wildlife Area. Hunting is prohibited, and so is possessing "
        "equipment that could be used for hunting, unless the regulation's own "
        "schedule authorises it for this area. It does not."
    ),
    "nwa_waterfowl": (
        "National Wildlife Area where the regulation authorises sport hunting "
        "of waterfowl only, in areas the Minister designates. Those designated "
        "areas are not published as a boundary, so this outline cannot tell you "
        "whether your spot is one of them. Nothing else may be hunted, and no "
        "toxic shot may be used."
    ),
    "nwa_no_entry": (
        "National Wildlife Area you may not even enter without a federal "
        "permit, let alone hunt."
    ),
    "nwa_unverified": (
        "Mapped by ECCC as a National Wildlife Area, but its name is not in the "
        "current regulation schedule, so we could not confirm which rules apply. "
        "Treat it as closed until Environment and Climate Change Canada says "
        "otherwise."
    ),
    "mbs_closed": (
        "Migratory Bird Sanctuary. Hunting migratory birds is prohibited, and "
        "separately you may not have any firearm or hunting appliance in your "
        "possession here at all. Together that closes it to hunting anything by "
        "any means, including walking through with a slung rifle after deer."
    ),
    "mbs_unverified": (
        "Mapped by ECCC as a Migratory Bird Sanctuary, but its name is not in "
        "the current regulation schedule, so we could not confirm which rules "
        "apply. Treat it as closed until Environment and Climate Change Canada "
        "says otherwise."
    ),
}


def query(params: dict) -> dict:
    url = f"{SERVICE}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": "OpenWoodsMap/1.0"})
    with urllib.request.urlopen(request, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(f"Non-JSON: {text[:160]!r}")
    return json.loads(text)


def fetch(where: str) -> list[dict]:
    features: list[dict] = []
    offset = 0
    while True:
        page = query(
            {
                "where": where,
                "outFields": FIELDS,
                "returnGeometry": "true",
                "outSR": "4326",
                "f": "geojson",
                "resultRecordCount": str(PAGE_SIZE),
                "resultOffset": str(offset),
            }
        )
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  fetched {len(features)}", flush=True)
        if len(batch) < PAGE_SIZE:
            return features
        offset += PAGE_SIZE


def stem(value: str) -> str:
    """Reduce a protected-area name to something both sources agree on.

    ECCC writes "Migratory Bird Sanctuary" where the regulation writes "Bird
    Sanctuary", splits several areas into named units the regulation does not
    distinguish, and differs on possessives: the schedule has St. Joseph's
    Island and Beckett Creek where CPCAD has St. Joseph Island and Becketts
    Creek. Stripping the designation, the unit suffix and any trailing s leaves
    a key that matches exactly or not at all -- a near miss is reported as
    unverified rather than guessed at.
    """
    text = (value or "").upper().replace("’", "'").replace("–", "-")
    text = re.split(r"\s+-\s+", text)[0]
    text = re.sub(r"\bMIGRATORY\b", " ", text)
    text = re.sub(r"\b(NATIONAL WILDLIFE AREA|BIRD SANCTUARY|WILDLIFE AREA)\b",
                  " ", text)
    text = re.sub(r"[^A-Z0-9 ]+", " ", text)
    words = [re.sub(r"S$", "", word) for word in text.split()]
    return " ".join(word for word in words if word)


def is_authority(name: str) -> bool:
    upper = (name or "").upper()
    return bool(
        re.search(r"CONSERVATION (AUTHORITY|FOUNDATION)", upper)
        or upper.strip() in AUTHORITY_ALIASES
    )


def quantize(geometry: dict, digits: int = 5) -> dict:
    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def prepare(raw: list[dict], tolerance: float, min_part: float) -> list[dict]:
    out, dropped = [], 0
    for feature in raw:
        geometry = feature.get("geometry")
        if not geometry:
            dropped += 1
            continue
        try:
            thinned = thin(valid(shape(geometry)), tolerance, min_part)
        except Exception:  # noqa: BLE001
            dropped += 1
            continue
        if not usable(thinned):
            dropped += 1
            continue
        out.append({**feature, "geometry": quantize(mapping(thinned))})
    if dropped:
        print(f"  WARNING: dropped {dropped} unusable geometries", file=sys.stderr)
    return out


def build_conservation_authority() -> int:
    print("Fetching Ontario conservation areas from CPCAD …")
    raw = fetch(f"LOC={ONTARIO} AND TYPE_E='Conservation Area'")
    if not raw:
        print("No conservation areas returned", file=sys.stderr)
        return 1
    prepared = prepare(raw, CA_SIMPLIFY, CA_MIN_PART)

    features: list[dict] = []
    authorities: set[str] = set()
    others: set[str] = set()
    for index, feature in enumerate(prepared, 1):
        props = feature.get("properties") or {}
        name = (props.get("NAME_E") or "Conservation area").strip()
        owner = (props.get("OWNER_E") or "").strip()
        manager = (props.get("MGMT_E") or "").strip() or owner
        # The permit comes from the conservation authority even where a
        # municipality runs the property day to day, so the authority is looked
        # for on both sides and the manager is only named when it is somebody
        # else. A tract with no authority on either side is a different
        # question: it is municipal or trust land that happens to be in CPCAD.
        authority = next(
            (party for party in (manager, owner) if is_authority(party)), ""
        )
        (authorities if authority else others).add(authority or manager or owner)

        properties: dict[str, object] = {
            "id": f"on-ca-{index}",
            "name": name,
            "hunting_allowed": None,
            "basis": "ca_permit" if authority else "conservation_permission",
            "permit_required": True,
            "authority": authority or manager,
        }
        if manager and manager != (authority or manager):
            properties["managed_by"] = manager
        if owner and owner not in {manager, authority}:
            properties["owner"] = owner
        if props.get("MPLAN_REF"):
            properties["management_plan"] = props["MPLAN_REF"]
        features.append(
            {"type": "Feature", "properties": properties,
             "geometry": feature["geometry"]}
        )

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "conservation_authority",
            "layer_role": "permission_required",
            "feature_count": len(features),
            "coverage": (
                "Conservation authority and other conserved properties Ontario "
                "authorities reported to CPCAD. Incomplete by construction."
            ),
            "coverage_incomplete": True,
            "coverage_note": (
                "CPCAD holds only what each authority chose to report, so this "
                "layer is not a register of conservation authority property. "
                "Grand River Conservation Authority is absent entirely and "
                "several others report a single property. A polygon here means "
                "you need that body's permission; the absence of one is not "
                "evidence that the land is open."
            ),
            "boundary_accuracy": "mapped",
            "default_name": "Conservation area",
            "tenure": "Conservation authority land — permit required",
            "basis_notes": {k: v for k, v in BASIS.items()
                            if k in {"ca_permit", "conservation_permission"}},
            "authorities": sorted(a for a in authorities if a),
            "other_managers": sorted(o for o in others if o),
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "authority": "Conservation Authorities Act, R.S.O. 1990, c. C.27",
            "note": (
                "Hunting on conservation authority land requires a permit from "
                "the authority. Fees, lotteries and outright closures vary by "
                "authority and by property, so the card names the authority to "
                "ask rather than stating a rule we cannot verify province-wide."
            ),
        },
        "features": features,
    }
    CA_OUT.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} conservation areas -> {CA_OUT} "
          f"({CA_OUT.stat().st_size / 1e6:.2f} MB)")
    print(f"  {len(authorities)} conservation authorities, "
          f"{len(others)} other managers")
    if others:
        print(f"  other managers: {', '.join(sorted(o for o in others if o))}")
    return 0


def build_federal_closure() -> int:
    if not RULES.is_file():
        print(f"Missing {RULES}. Run: python parse_federal_wildlife_regs.py",
              file=sys.stderr)
        return 1
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    nwa_rules = {stem(area["name"]): area for area in rules["nwa"]["areas"]}
    mbs_names = {stem(area["name"]) for area in rules["mbs"]["areas"]}

    print("Fetching Ontario NWAs and MBSs from CPCAD …")
    raw = fetch(
        f"LOC={ONTARIO} AND TYPE_E IN "
        "('National Wildlife Area','Migratory Bird Sanctuary')"
    )
    if not raw:
        print("No federal areas returned", file=sys.stderr)
        return 1
    prepared = prepare(raw, FED_SIMPLIFY, FED_MIN_PART)

    features: list[dict] = []
    unverified: list[str] = []
    counts = {"nwa_closed": 0, "nwa_waterfowl": 0, "nwa_no_entry": 0,
              "mbs_closed": 0, "nwa_unverified": 0, "mbs_unverified": 0}

    for index, feature in enumerate(prepared, 1):
        props = feature.get("properties") or {}
        name = (props.get("NAME_E") or "Federal protected area").strip()
        kind = props.get("TYPE_E") or ""
        key = stem(name)
        properties: dict[str, object] = {
            "id": f"on-fed-{index}",
            "name": name,
            "designation": kind,
        }

        if kind == "National Wildlife Area":
            rule = nwa_rules.get(key)
            if rule is None:
                basis = "nwa_unverified"
                properties["hunting_allowed"] = False
                unverified.append(name)
            elif rule["no_entry"]:
                basis = "nwa_no_entry"
                properties["hunting_allowed"] = False
                properties["entry_prohibited"] = True
                properties["reg_paragraph"] = rule["no_entry_paragraph"]
            elif rule["hunting_authorized"]:
                # Waterfowl only, and only where the Minister designates. The
                # designation is not published, so this outline cannot place a
                # point inside or outside it and must not read as open.
                basis = "nwa_waterfowl"
                properties["hunting_allowed"] = None
                properties["hunting_extent"] = "part"
                properties["reg_text"] = rule["hunting_activities"][0]
            else:
                basis = "nwa_closed"
                properties["hunting_allowed"] = False
            properties["citation"] = rules["nwa"]["citation"]
        else:
            if key in mbs_names:
                basis = "mbs_closed"
            else:
                basis = "mbs_unverified"
                unverified.append(name)
            properties["hunting_allowed"] = False
            properties["firearm_prohibited"] = True
            properties["citation"] = rules["mbs"]["citation"]

        properties["basis"] = basis
        counts[basis] += 1
        features.append(
            {"type": "Feature", "properties": properties,
             "geometry": feature["geometry"]}
        )

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "federal_closure",
            "layer_role": "closure",
            "feature_count": len(features),
            "coverage": (
                "National Wildlife Areas and Migratory Bird Sanctuaries in "
                "Ontario. Closed to hunting except waterfowl in designated "
                "areas of Big Creek and Long Point."
            ),
            "boundary_accuracy": "mapped",
            "default_name": "Federal protected area",
            "tenure": "Federal protected area — closed to hunting",
            "basis_notes": {k: v for k, v in BASIS.items() if k.startswith(
                ("nwa_", "mbs_"))},
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "hunting_source": (
                f"{rules['nwa']['citation']}; {rules['mbs']['citation']}"
            ),
            "hunting_source_url": rules["nwa"]["source"],
            "hunting_currency_date": max(
                rules["nwa"]["currency_date"], rules["mbs"]["currency_date"]
            ),
            "extent_note": (
                "Hunting is authorised only in areas the Minister designates "
                "inside this boundary. Those designations are not published as "
                "geometry, so this outline cannot tell you whether your spot is "
                "one of them."
            ),
            "unverified_areas": unverified,
            "note": (
                "The boundaries are ECCC's; the prohibitions are the "
                "regulations'. In a sanctuary the possession of any firearm or "
                "hunting appliance is an offence in its own right, so it is "
                "closed to hunting anything by any means, not only to "
                "waterfowling."
            ),
        },
        "features": features,
    }
    FED_OUT.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} federal areas -> {FED_OUT} "
          f"({FED_OUT.stat().st_size / 1e6:.2f} MB)")
    print("  " + ", ".join(f"{k}={v}" for k, v in counts.items() if v))
    if unverified:
        print(f"  UNVERIFIED against the schedule: {', '.join(unverified)}",
              file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=["ca", "federal"])
    args = parser.parse_args()
    status = 0
    if args.only != "federal":
        status |= build_conservation_authority()
    if args.only != "ca":
        status |= build_federal_closure()
    return status


if __name__ == "__main__":
    raise SystemExit(main())
