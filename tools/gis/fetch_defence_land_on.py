#!/usr/bin/env python3
"""Build ON defence_land from the Directory of Federal Real Property.

National Defence holds 140 Ontario properties, and the three that matter to a
hunter are enormous: Petawawa at 24,229 ha, Borden at 8,111 and Meaford at
7,685. They sit in bush, they are unfenced for most of their perimeter, and
nothing else in the app would say anything about them.

The honest answer is not a flat "no hunting". Some bases run their own
controlled hunts, administered by the base and open to civilians who apply,
qualify and register daily. Whether one is running, where, and when is not in
this dataset or any other machine-readable source, and it changes year to year,
so the card says the ground is closed to hunting unless you are in a hunt the
base itself administers, and links to the property's own DFRP record rather than
naming programmes we would have to keep current.

Armouries and urban operations facilities are kept even though nobody would try
to hunt them. They are small, and dropping a closed property because we assume
nobody would want it is the wrong instinct for this app.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape

from geomutil import thin, usable, valid

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/defence_land.geojson"

SERVICE = (
    "https://idgsi-rpgdi-arcgis.spac-pspc.gc.ca/gisserver/rest/services/"
    "Hosted/DFRP_PUBLIC/FeatureServer/4/query"
)
FIELDS = (
    "property_number,name_en,custodian_en,primary_use_en,municipality_en,"
    "land_area,property_link_en"
)
PAGE_SIZE = 200
SIMPLIFY = 0.0001
MIN_PART = 1e-9

SOURCE = "Directory of Federal Real Property, Treasury Board of Canada Secretariat"
SOURCE_URL = "https://www.tbs-sct.canada.ca/dfrp-rbif/home-accueil-eng.aspx"
LICENSE = "Open Government Licence – Canada"
LICENSE_URL = "https://open.canada.ca/en/open-government-licence-canada"

BASIS = {
    "dnd_closed": (
        "Federal defence property. It is closed to public hunting, and much of "
        "it is closed to entry: training areas hold unexploded ordnance and live "
        "ranges. Some bases do run their own controlled hunts that civilians can "
        "apply for, with a mandatory safety briefing and daily registration at "
        "Range Control, but whether one is running here is not published as data "
        "and changes year to year. Ask the base before you go anywhere near it."
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


def quantize(geometry: dict, digits: int = 5) -> dict:
    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--province", default="Ontario")
    args = parser.parse_args()

    print(f"Fetching {args.province} National Defence property from DFRP …")
    raw = fetch(
        f"province_en='{args.province}' AND custodian_en='National Defence'"
    )
    if not raw:
        print("No defence properties returned", file=sys.stderr)
        return 1

    features: list[dict] = []
    dropped = 0
    hectares = 0.0
    for index, feature in enumerate(raw, 1):
        geometry = feature.get("geometry")
        props = feature.get("properties") or {}
        if not geometry:
            dropped += 1
            continue
        try:
            thinned = thin(valid(shape(geometry)), SIMPLIFY, MIN_PART)
        except Exception:  # noqa: BLE001
            dropped += 1
            continue
        if not usable(thinned):
            dropped += 1
            continue

        area = props.get("land_area") or 0
        hectares += float(area)
        properties: dict[str, object] = {
            "id": f"on-dnd-{props.get('property_number') or index}",
            "name": (props.get("name_en") or "Defence property").strip(),
            "hunting_allowed": False,
            "basis": "dnd_closed",
            "designation": props.get("primary_use_en") or "Defence property",
            "custodian": props.get("custodian_en") or "National Defence",
        }
        if area:
            properties["area_ha"] = round(float(area), 1)
        # The DFRP record is the authority on who holds the property and who to
        # contact, and it stays current without us reshipping a pack.
        if props.get("property_link_en"):
            properties["record_url"] = props["property_link_en"]
        features.append(
            {"type": "Feature", "properties": properties,
             "geometry": quantize(mapping(thinned))}
        )

    if dropped:
        print(f"  WARNING: dropped {dropped} unusable geometries", file=sys.stderr)

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "defence_land",
            "layer_role": "closure",
            "feature_count": len(features),
            "coverage": (
                "National Defence property in Ontario, from armouries to the "
                "training areas at Petawawa, Borden and Meaford"
            ),
            "boundary_accuracy": "mapped",
            "default_name": "Defence property",
            "tenure": "National Defence property — closed to public hunting",
            "basis_notes": BASIS,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "note": (
                "Closed to public hunting. Base-administered controlled hunts do "
                "exist on some properties, but they are not published as data and "
                "change from year to year, so the app points at the property "
                "record instead of naming programmes it cannot keep current."
            ),
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} properties ({hectares:,.0f} ha) -> {args.out} "
          f"({args.out.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
