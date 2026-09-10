#!/usr/bin/env python3
"""Build ON first_nations from the Canada Lands Survey System.

Reserve land is federal land held for the use and benefit of a First Nation. An
Ontario hunting licence grants no right of access to it, which is a different
thing from hunting being unlawful there, and the difference matters enough to
get the wording right: the province simply has no jurisdiction to let you in.
So this layer reports "permission of the First Nation required" and never
"prohibited".

It is deliberately silent on two things it has no business asserting. It says
nothing about the harvesting rights of members, and nothing about Aboriginal or
treaty rights under s. 35 of the Constitution Act, 1982. It addresses one
question only: whether a licensed hunter looking for somewhere to hunt may treat
this ground as available. They may not, without asking.

Source is NRCan's Canada Lands Survey System, which is the survey-derived
federal boundary and carries a per-feature accuracy statement. Ontario's own LIO
Indian Reserve layer holds 246 polygons against CLSS's 203, the difference being
multipart reserves split into separate records rather than extra land; the
federal survey is the authority for a federal boundary, so CLSS is used.
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
OUT = ROOT / "data/on/overlays/first_nations.geojson"

SERVICE = (
    "https://proxyinternet.nrcan-rncan.gc.ca/arcgis/rest/services/CLSS-SATC/"
    "CLSS_Administrative_Boundaries/MapServer/0/query"
)
FIELDS = (
    "adminAreaId,adminAreaNameEng,adminAreaNameAlt1,distributionTypeEng,"
    "jurisdictionEng,absoluteAccuracyEng,webReference"
)
# The service caps a page at 500 and reserves are detailed, so pages stay small.
PAGE_SIZE = 100
SIMPLIFY = 0.0002
MIN_PART = 1e-9

SOURCE = "Aboriginal Lands of Canada Legislative Boundaries (Canada Lands Survey System), NRCan"
SOURCE_URL = "https://www.nrcan.gc.ca/maps-tools-publications/maps/canada-lands-survey-system"
LICENSE = "Open Government Licence – Canada"
LICENSE_URL = "https://open.canada.ca/en/open-government-licence-canada"

BASIS = {
    "reserve_permission": (
        "Reserve land, held federally for the use and benefit of the First "
        "Nation. Your provincial hunting licence does not grant access to it — "
        "the province has no authority to grant that — so hunting here needs the "
        "permission of the First Nation, and its own by-laws may govern how. "
        "This is about access, not about anyone's harvesting rights."
    ),
}

# CLSS states accuracy per feature; anything looser than 100 m is not a line to
# stand a rifle beside, and the map draws those differently.
APPROXIMATE = {"greater than 100 metres"}


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
    parser.add_argument("--jurisdiction", default="Ontario")
    args = parser.parse_args()

    print(f"Fetching {args.jurisdiction} reserves from CLSS …")
    raw = fetch(f"jurisdictionEng='{args.jurisdiction}'")
    if not raw:
        print("No reserves returned", file=sys.stderr)
        return 1

    features: list[dict] = []
    approximate = 0
    dropped = 0
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

        accuracy = (props.get("absoluteAccuracyEng") or "").strip()
        loose = accuracy.lower() in APPROXIMATE
        approximate += loose
        properties: dict[str, object] = {
            "id": f"on-fn-{props.get('adminAreaId') or index}",
            "name": (props.get("adminAreaNameEng") or "Reserve").strip(),
            "hunting_allowed": None,
            "basis": "reserve_permission",
            "permit_required": True,
            "designation": (props.get("distributionTypeEng") or "Indian Reserve"),
            "boundary_accuracy": "approximate" if loose else "mapped",
        }
        if accuracy:
            properties["survey_accuracy"] = accuracy
        if props.get("adminAreaNameAlt1"):
            properties["other_name"] = props["adminAreaNameAlt1"]
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
            "layer": "first_nations",
            "layer_role": "permission_required",
            "feature_count": len(features),
            "coverage": (
                "Reserve boundaries in Ontario from the Canada Lands Survey "
                "System"
            ),
            "boundary_accuracy": "mapped",
            "accuracy_note": (
                "Survey accuracy is stated per reserve and ranges from better "
                "than 2 m to greater than 100 m. The few looser than 100 m are "
                "drawn as approximate."
            ),
            "default_name": "Reserve",
            "tenure": "Reserve land — permission of the First Nation required",
            "basis_notes": BASIS,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "note": (
                "An Ontario hunting licence conveys no right of access to reserve "
                "land, so this layer reports that permission is required rather "
                "than that hunting is prohibited. It says nothing about the "
                "harvesting rights of members, or about Aboriginal or treaty "
                "rights."
            ),
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} reserves -> {args.out} "
          f"({args.out.stat().st_size / 1e6:.2f} MB)")
    if approximate:
        print(f"  {approximate} drawn as approximate (survey looser than 100 m)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
