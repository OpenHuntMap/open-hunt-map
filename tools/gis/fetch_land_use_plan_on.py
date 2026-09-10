#!/usr/bin/env python3
"""Build ON land_use_plan: the Far North boundary and the community plans.

This layer exists to answer a question the map otherwise answers badly. Tap a
Crown parcel in the Far North and there is usually no policy report, because the
Crown Land Use Policy Atlas thins out to nothing up there. The card used to read
that as "no land use policy covers this parcel", which is the wrong answer — it
states an absence of policy when what we actually have is an absence of atlas.

Measured rather than assumed, CLUPA is sparse in the Far North, not missing:
querying the CLUPA service by bounding box returns 11 polygons around Big Trout
Lake and 4 around Pikangikum, but zero around Fort Severn and zero around
Attawapiskat, against 717 near Thunder Bay and 234 near Sudbury. So the layer
lets the card say "the atlas is thin here" north of the line, and name the
community plan instead where one applies.

Four approved community based land use plans cover about 3.0M ha. They are
direction for Crown land planning, not hunting regulations, and the card must
not imply otherwise: they say what activities the plan area is managed for, and
a hunter still needs the season, the WMU and a licence.

The four plans outside the Far North (Ontario's Living Legacy, Madawaska
Highlands, Cochrane District, Temagami) are deliberately excluded. CLUPA covers
those areas densely, so the parcel already gets its own policy report and a
second competing link would only muddy it.
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
OUT = ROOT / "data/on/overlays/land_use_plan.geojson"

SERVICE = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open06/MapServer/30/query"
)
FIELDS = ("OGF_ID,LAND_USE_PLAN_NAME,YEAR_APPROVED,FAR_NORTH_IND,AREA_IN_HA,"
          "URL_ENGLISH")

# The province records this as a plan area alongside the plans themselves. It is
# the one feature that tells us where the atlas stops being reliable.
BOUNDARY_NAME = "Far North Boundary Line"

# Coarser than the tenure layers by design. Nothing legal turns on this outline —
# it selects which explanation the card shows — and the Far North polygon covers
# 45M ha, so a metre-accurate edge would cost megabytes to no purpose.
SIMPLIFY = 0.002
MIN_PART = 1e-7

SOURCE = "Land Use Plan Area, Ontario Ministry of Natural Resources (LIO)"
SOURCE_URL = "https://www.ontario.ca/page/land-use-planning-process-far-north"
LICENSE = "Open Government Licence – Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"

SCOPE_NOTES = {
    "far_north": (
        "You are north of the Far North boundary. The Crown Land Use Policy "
        "Atlas thins out to nothing across much of this ground, so a parcel with "
        "no policy report here usually means the atlas does not reach it rather "
        "than that no direction exists. Hunting is still governed by the season "
        "and the WMU."
    ),
    "community": (
        "A community based land use plan covers this ground. It directs how "
        "Crown land here is planned and managed and is not a hunting regulation, "
        "so it neither opens nor closes the season — but it is the closest thing "
        "to area-specific direction the province publishes for the Far North."
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


def quantize(geometry: dict, digits: int = 4) -> dict:
    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    print("Fetching land use plan areas from LIO …")
    index = query(
        {"where": "1=1", "outFields": f"OBJECTID,{FIELDS}",
         "returnGeometry": "false", "f": "json"}
    ).get("features") or []
    if not index:
        print("No plan areas returned", file=sys.stderr)
        return 1
    print(f"  {len(index)} plan areas in the source")

    features: list[dict] = []
    hectares = 0.0
    skipped: list[str] = []
    for row in index:
        props = row.get("attributes") or {}
        name = (props.get("LAND_USE_PLAN_NAME") or "").strip()
        far_north = (props.get("FAR_NORTH_IND") or "").strip().lower() == "yes"
        boundary = name == BOUNDARY_NAME
        if not (far_north or boundary):
            skipped.append(name or "unnamed")
            continue
        # One feature per request, with the server doing the first simplify pass.
        # The Far North polygon covers 45M ha and the service answers a request
        # for its full-resolution geometry with an HTML error page.
        geometry = (query({
            "where": f"OBJECTID={props['OBJECTID']}",
            "outFields": "OBJECTID", "returnGeometry": "true",
            "outSR": "4326", "maxAllowableOffset": str(SIMPLIFY),
            "f": "geojson",
        }).get("features") or [{}])[0].get("geometry")
        if not geometry:
            skipped.append(f"{name} (no geometry)")
            continue
        try:
            thinned = thin(valid(shape(geometry)), SIMPLIFY, MIN_PART)
        except Exception:  # noqa: BLE001
            skipped.append(f"{name} (bad geometry)")
            continue
        if not usable(thinned):
            skipped.append(f"{name} (empty after simplify)")
            continue

        scope = "far_north" if boundary else "community"
        properties: dict[str, object] = {
            "id": f"on-lup-{props.get('OGF_ID')}",
            "name": "Far North of Ontario" if boundary else name,
            "plan_scope": scope,
            "hunting_allowed": None,
            "basis": f"land_use_plan_{scope}",
            # Coarse on purpose, and the card must not let anyone stand on it.
            "boundary_accuracy": "approximate",
        }
        if not boundary:
            hectares += float(props.get("AREA_IN_HA") or 0)
            if props.get("YEAR_APPROVED"):
                properties["year_approved"] = int(props["YEAR_APPROVED"])
        if props.get("URL_ENGLISH"):
            properties["record_url"] = props["URL_ENGLISH"]
        features.append(
            {"type": "Feature", "properties": properties,
             "geometry": quantize(mapping(thinned))}
        )

    if skipped:
        print(f"  skipped {len(skipped)} outside the Far North: "
              f"{', '.join(sorted(skipped))}")

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "land_use_plan",
            "layer_role": "context",
            "feature_count": len(features),
            "coverage": (
                "The Far North boundary, plus the four approved community based "
                f"land use plans inside it ({hectares:,.0f} ha)"
            ),
            "boundary_accuracy": "approximate",
            "accuracy_note": (
                "Simplified to roughly 200 m. It decides which explanation the "
                "card shows, and nothing legal turns on the line itself."
            ),
            "default_name": "Land use plan area",
            "tenure": "Land use planning direction — not a hunting regulation",
            "basis_notes": SCOPE_NOTES,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "note": (
                "Context only. A community based land use plan says how Crown "
                "land is managed, not whether you may hunt: seasons and WMUs "
                "still decide that. The layer's real job is to stop the app "
                "reporting a parcel the atlas never reached as a parcel with no "
                "policy."
            ),
        },
        "features": features,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} plan areas -> {args.out} "
          f"({args.out.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
