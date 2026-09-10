#!/usr/bin/env python3
"""Build ON municipal_forest from Ontario's Agreement Forest Area parcels.

Southern Ontario has almost no Crown land, so the public land people actually
hunt there is county, regional and municipal forest. Ontario publishes those
tracts at parcel level in Agreement Forest Area, which is what lets us draw the
real patchwork of public lots instead of one blob over the private land between
them.

The dataset carries no ownership attribute, so ownership is inferred from the
tract name and only clearly public owners are kept -- a private woodlot must
never render as public land. Everything dropped is reported at the end so the
exclusions stay reviewable.

Provenance caveats, surfaced in the layer metadata rather than hidden:
  * Ontario has deprecated this dataset; records were verified 1997-1998.
  * Positional accuracy is mostly "Reliable (to 100m)".
  * Being public land is not permission to hunt. Only the four City of Ottawa
    forestry tracts named in the Discharge of Firearms By-law are flagged as
    huntable; every other tract is left unknown for the user to confirm.
"""

from __future__ import annotations

import io
import json
import re
import urllib.request
import zipfile
from collections import defaultdict
from pathlib import Path

import shapefile
from shapely.geometry import mapping, shape
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/municipal_forest.geojson"
CACHE = Path(__file__).resolve().parent / "_tmp_agreefor.zip"
SHP_STEM = "AGREEFOR_SHP/AGREEMENT_FOREST_AREA"

SOURCE_URL = (
    "https://data.ontario.ca/dataset/03700c14-5e9a-449e-a8f9-7ac3315bea91/"
    "resource/13f40cdc-db28-4fbe-b0be-ef3dda955690/download/agreefor_shp.zip"
)
SOURCE = "Ontario Agreement Forest Area (Geospatial Ontario)"
LICENSE = "Open Government Licence – Ontario"
LICENSE_URL = "https://www.ontario.ca/page/open-government-licence-ontario"

# Ordered: the first pattern that matches a tract name wins.
OWNER_PATTERNS: list[tuple[str, str]] = [
    (r"CONSERVATION\s+AUTHORITY|\bTRCA\b|GANARASKA|SOUTH\s+NATION"
     r"|OTONABEE\s+REGION|NAPANEE|RAISIN\s+REGION", "conservation_authority"),
    (r"COUNTY\s+(AGREEMENT\s+)?FOREST|COUNT\s+FOREST"
     r"|SIMCOE\s+COUNTY|GREY\s+COUNTY|BRUCE\s+COUNTY|VICTORIA\s+COUNTY"
     r"|NORTHUMBERLAND\s+COUNTY|PETERBOROUGH\s+COUNTY|LENNOX"
     r"|LANARK|S\.?D\.?G\.?\s+FOREST|CHARLOTTENBURG|LIMERICK|LAROSE", "county"),
    (r"REGION(AL)?\s+FOREST|DURHAM\s+REGION|HALTON\s+REGION|YORK\s+REGION",
     "region"),
    (r"MARLBORO|CARP\s+HILLS|PINERY\s+LONG\s+SWAMP|TORBOLTON"
     r"|CUMBERLAND\s+FOREST|CORKERY", "municipal"),
]

# Spelling and abbreviation fixes present in the source records.
NAME_FIXES = {
    "MARLBOROGH FOREST": "MARLBOROUGH FOREST",
    "LANARK COUNT FOREST": "LANARK COUNTY FOREST",
    "S.D.G FOREST": "S.D.G. FOREST",
    "CENTENIAL LAKE TRACT": "CENTENNIAL LAKE TRACT",
}

# The forestry lands By-law 2002-344 exempts from Ottawa's public-land firearm
# discharge prohibition, i.e. the ones the City states may be hunted.
OTTAWA_HUNTABLE = ("MARLBORO", "CARP HILLS", "PINERY LONG SWAMP", "CORKERY")

BASIS_CODES = {
    "ottawa_forestry_bylaw": (
        "A City of Ottawa forestry tract named in the Discharge of Firearms "
        "By-law 2002-344, which exempts it from the ban on discharging a "
        "firearm on public land. Provincial seasons and licences still apply."
    ),
    "municipal_discretion": (
        "County, regional or municipal forest. The owner sets access rules and "
        "many tracts require a permit or prohibit hunting outright - confirm "
        "with the municipality before hunting."
    ),
    "conservation_authority": (
        "Conservation authority forest. Hunting is commonly prohibited or "
        "permit-only on authority land - confirm with the authority first."
    ),
}

ACRONYMS = {"SDG", "S.D.G.", "TRCA", "NCC", "CSLA", "II", "III", "IV", "VI",
            "VII", "VIII", "IX", "XI", "XII"}


def download() -> bytes:
    if CACHE.exists():
        print(f"using cached {CACHE.name}")
        return CACHE.read_bytes()
    print("downloading Agreement Forest Area …", flush=True)
    request = urllib.request.Request(
        SOURCE_URL, headers={"User-Agent": "OpenWoodsMap/0.1"}
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        payload = response.read()
    CACHE.write_bytes(payload)
    return payload


def owner_type(name: str) -> str | None:
    for pattern, kind in OWNER_PATTERNS:
        if re.search(pattern, name):
            return kind
    return None


def pretty(name: str) -> str:
    parts = []
    for word in name.split():
        stripped = word.replace(".", "")
        # Keep short dotted forms (S.D.G., D.R.I.) and known acronyms intact.
        if stripped in ACRONYMS or word in ACRONYMS or (
            "." in word and len(stripped) <= 4
        ):
            parts.append(word)
        elif word.startswith("(") and word.endswith(")"):
            parts.append("(" + word[1:-1].capitalize() + ")")
        else:
            parts.append(word.capitalize())
    return " ".join(parts).replace(";", " —")


def quantize(geometry: dict, digits: int = 5) -> dict:
    """Round coordinates. Source accuracy is ~100 m, so 5 dp (~1 m) is ample."""

    def walk(value):
        if isinstance(value, (int, float)):
            return round(float(value), digits)
        return [walk(item) for item in value]

    return {"type": geometry["type"], "coordinates": walk(geometry["coordinates"])}


def main() -> int:
    archive = zipfile.ZipFile(io.BytesIO(download()))
    reader = shapefile.Reader(
        shp=io.BytesIO(archive.read(f"{SHP_STEM}.shp")),
        dbf=io.BytesIO(archive.read(f"{SHP_STEM}.dbf")),
        shx=io.BytesIO(archive.read(f"{SHP_STEM}.shx")),
    )

    features: list[dict] = []
    kept_area: defaultdict[str, float] = defaultdict(float)
    dropped: defaultdict[str, list[float]] = defaultdict(lambda: [0, 0.0])
    huntable = 0

    for index, record in enumerate(reader.iterShapeRecords(), 1):
        attributes = record.record.as_dict()
        raw_name = (attributes.get("OFFICIAL_N") or "").strip().upper()
        raw_name = NAME_FIXES.get(raw_name, raw_name)
        area_ha = float(attributes.get("SYSTEM_CAL") or 0) / 10_000.0

        kind = owner_type(raw_name)
        if kind is None:
            entry = dropped[raw_name]
            entry[0] += 1
            entry[1] += area_ha
            continue

        try:
            geometry = shape(record.shape.__geo_interface__)
        except Exception as error:  # noqa: BLE001
            print(f"skip {raw_name}: {error}")
            continue
        if not geometry.is_valid:
            geometry = make_valid(geometry)
        if geometry.is_empty or geometry.geom_type not in {
            "Polygon",
            "MultiPolygon",
        }:
            continue

        if any(token in raw_name for token in OTTAWA_HUNTABLE):
            hunting: bool | None = True
            basis = "ottawa_forestry_bylaw"
            huntable += 1
        elif kind == "conservation_authority":
            hunting = None
            basis = "conservation_authority"
        else:
            hunting = None
            basis = "municipal_discretion"

        properties: dict[str, object] = {
            "id": f"on-mf-{int(attributes.get('OGF_ID') or index)}",
            "name": pretty(raw_name),
            "owner_type": kind,
            "basis": basis,
            "area_ha": round(area_ha, 1),
        }
        if hunting is not None:
            properties["hunting_allowed"] = hunting
        # Kept in the source's upper case: these are legal lot-and-concession
        # descriptions, and title-casing mangles the Roman numerals.
        lot = (attributes.get("LOCATION_D") or "").strip()
        if lot:
            properties["lot"] = lot

        features.append(
            {
                "type": "Feature",
                "properties": properties,
                "geometry": quantize(mapping(geometry)),
            }
        )
        kept_area[raw_name] += area_ha

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "municipal_forest",
            "layer_role": "public_forest",
            "feature_count": len(features),
            "coverage": (
                "Ontario county, regional, municipal and conservation "
                "authority forest tracts (Agreement Forest Area), at parcel "
                "level. Land between tracts is private."
            ),
            "boundary_accuracy": "mapped",
            "accuracy_note": (
                "Parcel outlines come from provincial records verified in "
                "1997-1998 with positional accuracy around 100 m, and Ontario "
                "has since deprecated the dataset. Treat edges as approximate "
                "and expect some tracts to have changed hands."
            ),
            "default_name": "Municipal or county forest",
            "tenure": "Public forest — county, regional or municipal",
            "basis_notes": BASIS_CODES,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "source": SOURCE,
            "source_url": (
                "https://data.ontario.ca/dataset/agreement-forest-area"
            ),
            "note": (
                "Tracts whose owner could not be established from the record "
                "are excluded, so this layer under-reports rather than showing "
                "private woodlots as public."
            ),
        },
        "features": features,
    }
    OUT.write_text(json.dumps(payload), encoding="utf-8")

    total_kept = sum(kept_area.values())
    total_dropped = sum(entry[1] for entry in dropped.values())
    print(
        f"Wrote {len(features)} parcels across {len(kept_area)} tracts "
        f"(~{total_kept:,.0f} ha) -> {OUT} "
        f"({OUT.stat().st_size / 1e6:.2f} MB)"
    )
    print(f"  flagged huntable (Ottawa by-law): {huntable} parcels")
    print(
        f"  excluded {sum(int(e[0]) for e in dropped.values())} parcels across "
        f"{len(dropped)} tracts (~{total_dropped:,.0f} ha) with no "
        f"establishable public owner; largest:"
    )
    for name, (count, area) in sorted(
        dropped.items(), key=lambda item: -item[1][1]
    )[:10]:
        print(f"    {area:9,.0f} ha  {int(count):4d}p  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
