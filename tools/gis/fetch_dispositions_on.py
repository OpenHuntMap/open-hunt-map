#!/usr/bin/env python3
"""Build ON crown_disposition from Ontario's non-freehold Crown dispositions.

The Crown tenure layer answers "does the Crown own this?". On its own that is
enough to send someone toward a lake that turns out to have a family's hunt camp
on the shore, because a land use permit does not change who owns the land and so
never shows up in the tenure fabric. Near Round Lake in Renfrew County the
tenure layer draws unbroken Crown parcels over 64 dispositions, most of them
permits for private recreation camps.

None of this is a hunting closure and the layer must not imply one. The Crown
still owns the ground and the Fish and Wildlife Conservation Act says nothing
about it. What a lease, permit or licence of occupation does is give somebody
else the right to occupy a described piece of it, and an occupier can prohibit
entry under the Trespass to Property Act. So the honest reading is "you are
probably allowed to hunt here and somebody else is probably living here", which
is why every feature ships as conditional rather than closed.

Two deliberate scope decisions, both about weight rather than principle:

  * Easements are excluded. An easement over Crown land is a right of passage --
    a hydro corridor, a road allowance, a pipeline -- and it does not create the
    exclusive occupation this layer exists to warn about. They are also 4,453 of
    the 37,620 dispositions and, at 156 coordinates each against 35 for
    everything else, roughly two thirds of the layer's weight. Excluding them
    costs no warning and saves about 29 MB.
  * Geometry is simplified server-side to about 5 m. The province states its own
    location accuracy per feature, and it ranges from 1 m to 1000 m with most
    parcels at 20-100 m. Simplifying an order of magnitude inside the source's
    own error is honest; shipping 28 MB to preserve vertices the survey does not
    support is not.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

from shapely.geometry import shape

from geomutil import polygonal, quantized_valid, usable, valid

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/crown_disposition.geojson"

SERVICE = (
    "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/"
    "LIO_OPEN_DATA/LIO_Open08/MapServer/33"
)
SOURCE = "Crown Land – MNR Non-Freehold Dispositions (Land Information Ontario)"
SOURCE_URL = "https://geohub.lio.gov.on.ca/datasets/lio::crown-land-mnr-non-freehold-dispositions"
LICENSE = "Open Government Licence – Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"

PAGE = 2000
# In degrees of the output CRS. 0.00005 deg is roughly 5 m at this latitude.
SIMPLIFY_DEG = 0.00005
WHERE = "CLASS_SUBTYPE <> 'Crown Disposition Easement'"

# Coordinate decimals kept. 4 is about 8 m of longitude at 45 N, inside the
# stated error of 89% of these parcels and never the limiting factor for the
# rest, since simplification below is what sets their detail.
PRECISION = 4

# Each parcel is simplified against the accuracy the province states for it,
# never against a single number for the layer. 87% of these are mapped to 20 m
# or worse and carry far more vertices than that supports, but 3,604 of them are
# mapped to 1-5 m, and flattening those to a common tolerance would claim less
# precision than the survey actually has while still labelling them "mapped".
# A fifth of the stated error keeps the shape well inside it; the cap stops a
# 1000 m parcel becoming a triangle, the floor matches what the server already
# applied via maxAllowableOffset so precise parcels come through untouched.
SIMPLIFY_FRACTION_OF_ACCURACY = 0.2
SIMPLIFY_MAX_DEG = 0.00015
DEGREES_PER_METRE = 1 / 111_320

FIELDS = ",".join(
    [
        "OGF_ID",
        "CLASS_SUBTYPE",
        "PURPOSE_OF_DISPOSITION",
        "SITE_NAME",
        "AREA_IN_HA",
        "LICENCE_OF_OCCUPATION_TYPE",
        "LEASE_TYPE",
        "LOCATION_ACCURACY",
    ]
)

# Everything here is "occupied by someone else", never "closed to hunting". The
# distinction is the whole point of the layer, so it lives in the wording rather
# than in a flag the UI has to interpret.
BASIS_CODES = {
    "disposition_occupied": (
        "Crown land held by someone under a lease, land use permit or licence "
        "of occupation. The Crown still owns it and this is not a hunting "
        "closure, but another person holds the right to occupy the described "
        "area. Expect a camp, buildings or posted boundaries, and expect that "
        "the occupier may lawfully refuse entry."
    ),
    "disposition_mining": (
        "Crown land under a mining or exploratory licence of occupation. Not a "
        "hunting closure, but the holder has rights to the surface and there "
        "may be workings, equipment or posted boundaries on it."
    ),
}

# Anything the province maps worse than 100 m is drawn as an approximate
# boundary, because at that error the outline is a hint about where to look
# rather than a line to stand next to.
COARSE_ACCURACY = {
    "Within 200 metres",
    "Within 500 metres",
    "Within 1000 metres",
}

# Displayed instead of "Crown Disposition Land Use Permit", which is a database
# label rather than something a hunter would say.
KIND_LABELS = {
    "Crown Disposition Leases": "Crown lease",
    "Crown Disposition Land Use Permit": "Land use permit",
    "Crown Disposition Licence of Occupation": "Licence of occupation",
    "Crown Disposition Land Use Agreement": "Land use agreement",
    "Crown Disposition Beach Management Agreement": "Beach management agreement",
    "Crown Disposition Land Licensing Agreement": "Land licensing agreement",
}


def fetch_page(offset: int) -> dict:
    query = urllib.parse.urlencode(
        {
            "where": WHERE,
            "outFields": FIELDS,
            "outSR": "4326",
            "returnGeometry": "true",
            "maxAllowableOffset": SIMPLIFY_DEG,
            "resultOffset": offset,
            "resultRecordCount": PAGE,
            "f": "geojson",
        }
    )
    url = f"{SERVICE}/query?{query}"
    request = urllib.request.Request(url, headers={"User-Agent": "OpenWoodsMap/0.1"})
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def fetch_full_geometry(identifier: object) -> dict | None:
    """Re-fetch a parcel that server-side simplification collapsed to linework."""
    query = urllib.parse.urlencode(
        {
            "where": f"OGF_ID = {int(identifier)}",
            "outFields": "OGF_ID",
            "outSR": "4326",
            "returnGeometry": "true",
            "resultRecordCount": 1,
            "f": "geojson",
        }
    )
    request = urllib.request.Request(
        f"{SERVICE}/query?{query}",
        headers={"User-Agent": "OpenWoodsMap/0.1"},
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        payload = json.load(response)
    features = payload.get("features") or []
    return features[0].get("geometry") if features else None


def accuracy_metres(text: str | None) -> int | None:
    """The number out of "Within 100 metres", so it can be reasoned with."""
    if not text:
        return None
    digits = "".join(ch for ch in text if ch.isdigit())
    return int(digits) if digits else None


def simplify_for(geometry: dict, metres: int | None) -> dict:
    """Simplify a parcel against its own stated accuracy. See the constants."""
    try:
        from shapely.geometry import mapping, shape
    except ImportError:
        return geometry
    # No stated accuracy means no licence to discard detail, so it gets the
    # floor: whatever the server already did and nothing further.
    tolerance = min(
        SIMPLIFY_MAX_DEG,
        max(
            SIMPLIFY_DEG,
            (metres or 0) * SIMPLIFY_FRACTION_OF_ACCURACY * DEGREES_PER_METRE,
        ),
    )
    geom = polygonal(valid(shape(geometry)))
    if not usable(geom):
        return geometry
    geom = geom.simplify(tolerance, preserve_topology=True)
    return mapping(geom)


def clean(value) -> str | None:
    if value is None:
        return None
    text = " ".join(str(value).split())
    if not text or text.lower() in {"none", "null", "unknown"}:
        return None
    return text


def main() -> int:
    features: list[dict] = []
    kinds: Counter[str] = Counter()
    coarse = 0
    offset = 0

    while True:
        payload = fetch_page(offset)
        raw = payload.get("features") or []
        if not raw:
            break
        print(f"  fetched {len(raw)} at offset {offset}", flush=True)

        for index, feature in enumerate(raw, offset + 1):
            geometry = feature.get("geometry")
            if not geometry or geometry.get("type") not in {"Polygon", "MultiPolygon"}:
                continue
            attributes = feature.get("properties") or {}
            identifier = attributes.get("OGF_ID")
            parsed = polygonal(valid(shape(geometry)))
            if not usable(parsed) and identifier is not None:
                try:
                    recovered = fetch_full_geometry(identifier)
                except Exception as error:  # noqa: BLE001
                    recovered = None
                    print(f"  WARNING: OGF_ID {identifier} recovery failed: {error}")
                if recovered:
                    geometry = recovered
                    parsed = polygonal(valid(shape(geometry)))
                    if usable(parsed):
                        print(
                            f"  recovered OGF_ID {identifier} at full resolution",
                            flush=True,
                        )

            subtype = clean(attributes.get("CLASS_SUBTYPE")) or ""
            kind = KIND_LABELS.get(subtype, subtype or "Crown disposition")
            kinds[kind] += 1

            loo = clean(attributes.get("LICENCE_OF_OCCUPATION_TYPE"))
            mining = loo is not None and ("Mining" in loo or "Exploratory" in loo)

            accuracy = clean(attributes.get("LOCATION_ACCURACY"))
            approximate = accuracy in COARSE_ACCURACY
            if approximate:
                coarse += 1

            # Properties every feature would otherwise repeat are stated once in
            # the layer header instead and filled in by the app; only the
            # exceptions are carried here. Saying "conditional", "mapped" and
            # "disposition_occupied" 33,167 times costs 3 MB.
            properties = {
                "id": f"on-disp-{attributes.get('OGF_ID') or index}",
                "kind": kind,
            }
            if mining:
                properties["basis"] = "disposition_mining"
            if approximate:
                properties["boundary_accuracy"] = "approximate"
            for key, source_key in (
                ("purpose", "PURPOSE_OF_DISPOSITION"),
                ("name", "SITE_NAME"),
                ("licence_type", "LICENCE_OF_OCCUPATION_TYPE"),
                ("lease_type", "LEASE_TYPE"),
            ):
                value = clean(attributes.get(source_key))
                if value is not None:
                    properties[key] = value
            # As a number, not "Within 100 metres": a third of a megabyte of
            # identical prose, and the UI wants to compare it anyway.
            metres = accuracy_metres(accuracy)
            if metres is not None:
                properties["accuracy_m"] = metres
            area = attributes.get("AREA_IN_HA")
            if isinstance(area, (int, float)) and area > 0:
                properties["area_ha"] = round(float(area), 2)

            output_geometry = quantized_valid(
                shape(simplify_for(geometry, metres)),
                PRECISION,
                label=f"{properties['id']} ({properties.get('name', kind)})",
            )
            features.append(
                {
                    "type": "Feature",
                    "properties": properties,
                    "geometry": output_geometry,
                }
            )

        if len(raw) < PAGE:
            break
        offset += PAGE

    if not features:
        print("ERROR: no Crown dispositions returned")
        return 1

    out = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "crown_disposition",
            "layer_role": "occupancy",
            "feature_count": len(features),
            "coverage": (
                "Ontario Crown land held under lease, land use permit or "
                "licence of occupation, province-wide. Easements are excluded: "
                "a right of passage over Crown land does not create the "
                "exclusive occupation this layer warns about."
            ),
            # Read as the value for every feature that does not state its own.
            # Conditional, never False: see the module docstring. The Crown owns
            # this and wildlife law does not close it.
            "default_hunting_allowed": "conditional",
            "default_basis": "disposition_occupied",
            "boundary_accuracy": "mapped",
            "accuracy_note": (
                "The province states location accuracy per parcel, from 1 m to "
                "1000 m, and most sit at 20-100 m. Parcels mapped worse than "
                "100 m carry boundary_accuracy 'approximate', which the card "
                "warns about. Each parcel's outline is simplified against its own "
                "stated accuracy rather than a single tolerance for the layer, "
                "so the ones the province surveyed to a metre keep that detail."
            ),
            "default_name": "Crown land under disposition",
            "tenure": "Crown land occupied under a Crown disposition",
            "basis_notes": BASIS_CODES,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": SOURCE_URL,
            "authority": (
                "Public Lands Act; Trespass to Property Act s. 2 (an occupier "
                "may prohibit entry)"
            ),
            "note": (
                "Not a closure. Drawn over Crown tenure to say that somebody "
                "else occupies this piece of it, which the tenure layer alone "
                "cannot show."
            ),
        },
        "features": features,
    }
    OUT.write_text(json.dumps(out), encoding="utf-8")

    print(
        f"Wrote {len(features)} dispositions -> {OUT} "
        f"({OUT.stat().st_size / 1e6:.2f} MB)"
    )
    for kind, count in kinds.most_common():
        print(f"  {kind:32} {count:6d}")
    print(f"  drawn as approximate (>100 m): {coarse}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
