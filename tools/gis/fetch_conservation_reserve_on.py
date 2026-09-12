#!/usr/bin/env python3
"""Fetch Ontario's regulated conservation reserves (OGL-Ontario).

A conservation reserve is the mirror image of a provincial park. Under the
Provincial Parks and Conservation Reserves Act, 2006 a park is closed to hunting
unless a regulation opens it (s. 15 (1)), while a conservation reserve is *open*
unless a regulation closes it (s. 15 (3)). So this layer states a permission, and
unlike the parks layer it needs no schedule to do it.

Run parse_ppcra_on.py first; without the statute this script will not assert a
permission it cannot quote.

Why the layer is needed at all: comparing our card against iHunter's at Conroys
Marsh showed them naming a conservation reserve where we said only "General
rules apply, no local policy". Our only route to the designation was the Crown
Land Use Policy Atlas, whose planning area stops short of southern Ontario, so
every conservation reserve down there read to us as undesignated Crown land.
"""

from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import shape

from geomutil import quantized_valid, thin, usable, valid

ROOT = Path(__file__).resolve().parents[2]
RULES = ROOT / "data/on/rules/ppcra.json"
OUT = ROOT / "data/on/overlays/conservation_reserve.geojson"

LICENSE = "OGL-Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"
SOURCE = "Ontario LIO — Conservation Reserve Regulated"
URL = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open03/MapServer/2/query"
)
FIELDS = (
    "PROTECTED_AREA_NAME_ENG,STATUS_ENG,LEGISLATION,REGULATION_NUMBER,"
    "REGULATED_AREA"
)
# ~50 m, matching the parks layer. Reserves run from 13 ha to 188,000 ha and
# several are river or shoreline corridors, so anything coarser erases the small
# end of a layer whose whole purpose is to name ground we currently cannot.
SIMPLIFY = 0.0005

# Only regulated reserves carry s. 15 (3). A recommended reserve is not yet a
# conservation reserve, so if LIO ever mixes them into this layer the unregulated
# ones must not inherit the permission.
REGULATED_STATUS = "Regulated Conservation Reserve"

BASIS = "ppcra_s15_3"
BASIS_NOTES = {
    BASIS: (
        "Hunting is permitted in a conservation reserve unless a regulation "
        "under the Fish and Wildlife Conservation Act, 1997 prohibits it, so the "
        "designation itself is not a closure. A Crown game preserve over a "
        "reserve is such a prohibition, and where one applies it leads this "
        "card. A management plan is not: the Act says hunting here may not be "
        "constrained by zoning. Posted signs still govern on the ground."
    )
}


def query(params: dict) -> dict:
    full = f"{URL}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        full, headers={"User-Agent": "OpenWoodsMap/1.0"}
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(text[:200])
    return json.loads(text)


def fetch_all() -> list[dict]:
    features: list[dict] = []
    offset = 0
    page_size = 500
    while True:
        page = query(
            {
                "where": "1=1",
                "outFields": FIELDS,
                "returnGeometry": "true",
                "outSR": "4326",
                "f": "geojson",
                "resultRecordCount": str(page_size),
                "resultOffset": str(offset),
                "maxAllowableOffset": str(SIMPLIFY),
            }
        )
        batch = page.get("features") or []
        features.extend(batch)
        print(f"  offset={offset} total={len(features)}", flush=True)
        if len(batch) < page_size:
            break
        offset += page_size
    return features


def load_statute() -> tuple[str, str, str]:
    """The subsection, its verbatim text, and the consolidation date.

    The permission and the zoning exception are quoted together, because on their
    own s. 15 (3) invites the question a reserve's management plan would seem to
    answer, and s. 12 (3) is what forecloses it.
    """
    if not RULES.is_file():
        print(
            f"Missing {RULES}. Run: python parse_ppcra_on.py",
            file=sys.stderr,
        )
        return "", "", ""
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    provisions = rules["provisions"]
    permission = provisions["conservation_reserves"]
    zoning = provisions["conservation_reserve_zoning"]
    return (
        f"ss. {permission['subsection']} and {zoning['subsection']}",
        f"{permission['text']}\n\n{zoning['text']}",
        rules.get("currency_date") or "",
    )


def main() -> int:
    subsection, statute_text, currency = load_statute()
    if not statute_text:
        return 1

    print("Fetching conservation reserves …", flush=True)
    raw = fetch_all()

    out: list[dict] = []
    dropped_geometry = 0
    skipped_status: list[str] = []
    for i, feature in enumerate(raw, 1):
        props = feature.get("properties") or {}
        status = (props.get("STATUS_ENG") or "").strip()
        name = props.get("PROTECTED_AREA_NAME_ENG") or f"Conservation reserve {i}"
        if status != REGULATED_STATUS:
            skipped_status.append(f"{name} ({status or 'no status'})")
            continue
        geom = feature.get("geometry")
        if not geom:
            dropped_geometry += 1
            continue
        try:
            geometry = thin(valid(shape(geom)), SIMPLIFY)
        except Exception:  # noqa: BLE001
            dropped_geometry += 1
            continue
        if not usable(geometry):
            dropped_geometry += 1
            continue

        properties: dict[str, object] = {
            "id": f"on-conservation-reserve-{i}",
            "name": name,
            "province": "ON",
        }
        if props.get("REGULATION_NUMBER"):
            properties["regulation"] = f"O. Reg. {props['REGULATION_NUMBER']}"
        if props.get("REGULATED_AREA"):
            properties["area_ha"] = round(float(props["REGULATED_AREA"]), 1)
        output_geometry = quantized_valid(geometry, label=name)
        out.append(
            {
                "type": "Feature",
                "properties": properties,
                "geometry": output_geometry,
            }
        )

    if dropped_geometry:
        print(
            f"  WARNING: {dropped_geometry} reserve(s) lost to unusable geometry; "
            "a reserve that disappears is ground the card cannot name",
            file=sys.stderr,
        )
    if skipped_status:
        print(
            f"  {len(skipped_status)} feature(s) are not regulated reserves and "
            f"carry no {subsection} permission: {skipped_status[:5]}"
        )
    if not out:
        print("No regulated conservation reserves parsed", file=sys.stderr)
        return 1

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "layer": "conservation_reserve",
            "feature_count": len(out),
            "coverage": "Ontario regulated conservation reserves, province-wide",
            "boundary_accuracy": "mapped",
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "default_hunting_allowed": True,
            "default_basis": BASIS,
            "default_designation": "Conservation Reserve",
            "default_reg_text": statute_text,
            "basis_notes": BASIS_NOTES,
            "tenure": "Conservation reserve — regulated under the PPCRA",
            "citation": (
                f"Provincial Parks and Conservation Reserves Act, 2006, {subsection}"
            ),
            "hunting_source": (
                f"Provincial Parks and Conservation Reserves Act, 2006, {subsection}"
            ),
            "hunting_source_url": "https://www.ontario.ca/laws/statute/06p12",
            "hunting_currency_date": currency,
            "note": (
                "A conservation reserve is open to hunting by default, which is "
                "the opposite of a provincial park: the Act permits hunting "
                "unless a regulation under the Fish and Wildlife Conservation "
                "Act, 1997 prohibits it. Boundaries are the regulated ones, so "
                "the outline is the designation and not a tenure parcel — the "
                "Crown land layer underneath says who owns the ground."
            ),
        },
        "features": out,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    print(
        f"conservation reserves {len(out)} -> {OUT} "
        f"({OUT.stat().st_size / 1e6:.2f} MB), {subsection} "
        f"consolidated {currency}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
