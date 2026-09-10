#!/usr/bin/env python3
"""Build ON game_preserve from Ontario's Crown Game Preserve boundaries.

This is the one layer that exists to stop a hunt rather than suggest one. Under
FWCA s. 9(1) you may not hunt, trap or possess wildlife in a Crown game
preserve, and under s. 9(2) you may not even possess a firearm or trap there
unless you live on private land inside it. Without this layer the Crown tenure
fabric paints those same acres plain green, and the largest of them -- Chapleau,
roughly 7,000 km2 -- would read as ordinary huntable Crown land.

Because the failure mode is a charge under s. 9 rather than a wasted drive, this
layer keeps every preserve the province maps, including the three whose record
carries REGULATED_IND = No. Those are reported as unconfirmed rather than
silently asserted or silently dropped, so the user gets a warning and a reason
to call the district office.

Two exemptions are deliberately not modelled, as neither is mappable from this
dataset and both narrow the prohibition rather than widen it:
  * s. 102(1) -- someone living on the preserve, on their own land.
  * s. 102.1 -- one lot of the Himsworth preserve (North Himsworth, Lot 6,
    Concession XVIII) is exempt outright.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/game_preserve.geojson"

SERVICE = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open05/MapServer/7"
)
SOURCE = "Ontario Crown Game Preserve (Land Information Ontario)"
SOURCE_URL = "https://data.ontario.ca/dataset/crown-game-preserves"
LICENSE = "Open Government Licence – Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"

BASIS_CODES = {
    "fwca_s9": (
        "Crown game preserve. Under the Fish and Wildlife Conservation Act "
        "s. 9 you may not hunt, trap or possess wildlife here, and may not "
        "possess a firearm or trap unless you live on private land inside the "
        "preserve. This overrides the land being Crown land."
    ),
    "fwca_s9_unconfirmed": (
        "Mapped by Ontario as a Crown game preserve, but the provincial record "
        "does not confirm it is currently regulated. Treat it as closed to "
        "hunting until the MNR district office says otherwise."
    ),
}


def fetch() -> dict:
    query = urllib.parse.urlencode(
        {
            "where": "1=1",
            "outFields": "OGF_ID,OFFICIAL_NAME,REGULATED_IND,LOCATION_ACCURACY",
            "outSR": "4326",
            "returnGeometry": "true",
            "f": "geojson",
        }
    )
    url = f"{SERVICE}/query?{query}"
    print("fetching Crown Game Preserves …", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "OpenWoodsMap/0.1"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)


def quantize(geometry: dict, digits: int = 5) -> dict:
    """Round coordinates to ~1 m; the source is accurate to 10-100 m."""

    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def main() -> int:
    payload = fetch()
    raw = payload.get("features") or []
    if not raw:
        print("ERROR: no Crown Game Preserve polygons returned")
        return 1

    features: list[dict] = []
    unconfirmed: list[str] = []
    for index, feature in enumerate(raw, 1):
        geometry = feature.get("geometry")
        if not geometry or geometry.get("type") not in {"Polygon", "MultiPolygon"}:
            continue
        attributes = feature.get("properties") or {}
        name = (attributes.get("OFFICIAL_NAME") or "Crown game preserve").strip()
        # Explicitly flagged not-regulated is the only case we soften. A null
        # means the province simply left the field blank, which is not evidence
        # the preserve has been lifted.
        regulated = (attributes.get("REGULATED_IND") or "").strip().lower()
        confirmed = regulated != "no"
        if not confirmed:
            unconfirmed.append(name)

        features.append(
            {
                "type": "Feature",
                "properties": {
                    "id": f"on-cgp-{attributes.get('OGF_ID') or index}",
                    "name": name,
                    "hunting_allowed": False,
                    "basis": "fwca_s9" if confirmed else "fwca_s9_unconfirmed",
                },
                "geometry": quantize(geometry),
            }
        )

    out = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "game_preserve",
            "layer_role": "closure",
            "feature_count": len(features),
            "coverage": (
                "Ontario Crown game preserves, province-wide. Hunting and "
                "trapping are prohibited inside these boundaries."
            ),
            "boundary_accuracy": "mapped",
            "accuracy_note": (
                "Provincial boundaries accurate to between 10 m and 100 m. "
                "Exemptions for residents of a preserve and for one lot of the "
                "Himsworth preserve are not mapped."
            ),
            "default_name": "Crown game preserve",
            "tenure": "Crown game preserve — closed to hunting",
            "basis_notes": BASIS_CODES,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "authority": (
                "Fish and Wildlife Conservation Act, 1997 s. 9; "
                "O. Reg. 665/98 Part XIII"
            ),
            "note": (
                "Drawn over Crown land deliberately: this layer is the reason "
                "not to hunt ground that otherwise looks open."
            ),
        },
        "features": features,
    }
    OUT.write_text(json.dumps(out), encoding="utf-8")

    print(
        f"Wrote {len(features)} preserves -> {OUT} "
        f"({OUT.stat().st_size / 1e6:.2f} MB)"
    )
    if unconfirmed:
        print(
            f"  {len(unconfirmed)} flagged unconfirmed (REGULATED_IND=No): "
            f"{', '.join(sorted(unconfirmed))}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
