#!/usr/bin/env python3
"""Build the per-province place-name index from the CGNDB.

The Canadian Geographical Names Database (Natural Resources Canada) is the
federal register of approved geographical names, published per province as a
CSV of point features. It is the only free, openly licensed, nationally
consistent gazetteer, and it is small enough to ride inside a province pack,
which is what lets place-name search work with no signal and no geocoding API.

What this index is not, stated here because the app must not imply otherwise:

  * It is not a road network. CGNDB carries a `ROAD` class, but in Ontario and
    Quebec that class is 2,022 bridges, 577 trails, 518 portages and 373
    misfiled hills -- scattered entries with no coverage guarantee and almost
    no actual road names. Road search needs Statistics Canada's Road Network
    File. The class is dropped entirely rather than half-answered: a user who
    finds one trail here would reasonably conclude trails are searchable, and
    they are not.
  * It is not every named place. CGNDB holds names the Geographical Names Board
    of Canada has approved. A lake the locals name is absent, and the absence
    proves nothing. `coverage_incomplete` says so in the index metadata and the
    search UI repeats it where it matters, in the no-results state.

Usage:
  python fetch_cgndb.py                 # ON + QC, reusing any cached download
  python fetch_cgndb.py --province on
  python fetch_cgndb.py --force         # re-download the source CSVs
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TMP = Path(__file__).resolve().parent / "_tmp_cgndb"

SOURCE = "Canadian Geographical Names Database (Natural Resources Canada)"
SOURCE_URL = (
    "https://ftp.maps.canada.ca/pub/nrcan_rncan/vector/geobase_cgn_toponyme/"
    "prov_csv_eng/"
)
SPECIFICATION_URL = (
    "https://www.download-telecharger.services.geo.ca/pub/nrcan_rncan/vector/"
    "geobase_cgn_toponyme/doc/GeoBase_cgn_en_Specifications.pdf"
)
LICENSE = "Open Government Licence – Canada"
LICENSE_URL = "https://open.canada.ca/en/open-government-licence-canada"
# Wording fixed by section 4.1 of the licence. Reproduced verbatim, not
# paraphrased, because the licence specifies the sentence.
ATTRIBUTION = "Contains information licensed under the Open Government Licence – Canada."

PROVINCES = {
    "on": ("Ontario", "cgn_on_csv_eng"),
    "qc": ("Quebec", "cgn_qc_csv_eng"),
}

# Five decimals is ~1 m at these latitudes, and a CGNDB record is one point
# standing for a whole lake or township. Storing more would be precision the
# source never had. The index holds integers scaled by this factor rather than
# decimals, so the file format itself cannot carry a sixth decimal place.
COORDINATE_SCALE = 100_000

# CGNDB's own `Concise Code`, which is the source's classification rather than
# ours. Curated rather than taken whole: the excluded classes are mostly
# municipal and urban furniture whose presence would bury a lake under a
# hundred commemorative plaques, and one class (ROAD) whose presence would
# advertise a search this build cannot do.
#
#   water     a lake, a river, the rapid you take out above. RIVF is named
#             pools and fishing holes, which is precisely what an angler
#             searches for.
#   terrain   islands, points, shoals, hills. Shoals and reefs are kept
#             because they are what a boat needs to know about.
#   populated how you find the nearest town, and the named localities and
#             former post offices that are still how back roads are described.
#   admin     parks, conservation reserves, geographic townships, counties,
#             municipalities, reserves. The app already draws most of these as
#             layers; being able to type the name is the other half.
#   vegetation wetlands, marshes, swamps, woods -- waterfowl ground.
#   built     only what stands in the bush: boat launches, docks, lighthouses,
#             locks, campgrounds, seasonal camps, and military ranges the app
#             already warns about.
#   under     caves.
#   maritime  offshore banks. Four records across both provinces; kept because
#             they are named natural features, not because they matter much.
INCLUDED_CODES = {
    "LAKE", "RIV", "BAY", "CHAN", "FALL", "RAP", "RIVF", "SPRG",
    "ISL", "CAPE", "SHL", "MTN", "BCH", "VALL", "CLF", "PLN", "CRAT",
    "UNP", "TOWN", "CITY", "VILG", "HAM",
    "PARK", "GEOG", "MUN1", "MUN2", "IR", "PROV",
    "VEGL", "FOR",
    "MAR", "MIL", "CAMP",
    "CAVE",
    "SEAU",
}

# Kept as data rather than a comment so the index can state what was dropped.
EXCLUDED_CODES = {
    "ROAD": (
        "Bridges, trails and portages with no coverage guarantee, and no road "
        "network. Road search needs the Statistics Canada Road Network File."
    ),
    "HYDR": "Dams, drains, generating and pumping stations.",
    "SITE": "Monuments, plaques, plazas, public buildings, parking lots.",
    "RECR": "Libraries, arenas, community and sports centres.",
    "RES": "Quarries, mines, pits, community gardens.",
    "AIR": "Airports, terminals, seaplane bases.",
}


def download(province_id: str, *, force: bool) -> bytes:
    stem = PROVINCES[province_id][1]
    TMP.mkdir(parents=True, exist_ok=True)
    archive = TMP / f"{stem}.zip"
    if force or not (archive.exists() and archive.stat().st_size > 100_000):
        url = f"{SOURCE_URL}{stem}.zip"
        print(f"downloading {url} …", flush=True)
        request = urllib.request.Request(
            url, headers={"User-Agent": "OpenWoodsMap/0.1"}
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            archive.write_bytes(response.read())
        print(
            f"  saved {archive.name} ({archive.stat().st_size / 1e6:.1f} MB)",
            flush=True,
        )
    else:
        print(f"using cached {archive.name}", flush=True)

    with zipfile.ZipFile(archive) as zf:
        members = [name for name in zf.namelist() if name.lower().endswith(".csv")]
        if len(members) != 1:
            raise RuntimeError(f"{archive.name}: expected one CSV, found {members}")
        return zf.read(members[0])


def sort_key(name: str) -> str:
    """Fold accents and case for a stable, locale-independent record order.

    Sort order only. The app folds its own records and its own query with one
    Dart function, so what matters there is that those two agree with each
    other, not that either agrees with this.
    """
    stripped = "".join(
        ch
        for ch in unicodedata.normalize("NFD", name)
        if not unicodedata.combining(ch)
    )
    return stripped.casefold()


def build(province_id: str, *, force: bool) -> Path:
    province_name = PROVINCES[province_id][0]
    raw = download(province_id, force=force)
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))

    required = {
        "Geographical Name",
        "Generic Term",
        "Concise Code",
        "Latitude",
        "Longitude",
        "Location",
    }
    missing = required - set(reader.fieldnames or [])
    if missing:
        raise RuntimeError(
            f"{province_id}: CGNDB CSV is missing {sorted(missing)}. "
            f"The published schema has changed; re-read {SPECIFICATION_URL} "
            f"before trusting this index."
        )

    total = 0
    dropped: dict[str, int] = {}
    seen: set[tuple] = set()
    records: list[tuple[str, str, str, int, int]] = []
    for row in reader:
        total += 1
        code = (row["Concise Code"] or "").strip()
        if code not in INCLUDED_CODES:
            dropped[code] = dropped.get(code, 0) + 1
            continue
        name = (row["Geographical Name"] or "").strip()
        if not name:
            dropped["(unnamed)"] = dropped.get("(unnamed)", 0) + 1
            continue
        try:
            latitude = round(float(row["Latitude"]) * COORDINATE_SCALE)
            longitude = round(float(row["Longitude"]) * COORDINATE_SCALE)
        except (TypeError, ValueError):
            dropped["(no coordinate)"] = dropped.get("(no coordinate)", 0) + 1
            continue

        feature_type = (row["Generic Term"] or "").strip() or code
        # The county or district a name sits in, which is the only thing that
        # tells 75 Mud Lakes apart. Blank on a few hundred Ontario records,
        # where the UI falls back to the province.
        context = (row["Location"] or "").strip()

        key = (name, feature_type, latitude, longitude)
        if key in seen:
            continue
        seen.add(key)
        records.append((name, feature_type, context, latitude, longitude))

    records.sort(key=lambda record: (sort_key(record[0]), record[1], record[3]))

    types: list[str] = []
    type_ids: dict[str, int] = {}
    contexts: list[str] = []
    context_ids: dict[str, int] = {}
    for _, feature_type, context, _, _ in records:
        if feature_type not in type_ids:
            type_ids[feature_type] = len(types)
            types.append(feature_type)
        if context not in context_ids:
            context_ids[context] = len(contexts)
            contexts.append(context)

    payload = {
        "metadata": {
            "crs": "EPSG:4326",
            "province": province_id,
            "province_name": province_name,
            "record_count": len(records),
            "coordinate_scale": COORDINATE_SCALE,
            "source": SOURCE,
            "source_url": f"{SOURCE_URL}{PROVINCES[province_id][1]}.zip",
            "specification_url": SPECIFICATION_URL,
            "license": LICENSE,
            "license_url": LICENSE_URL,
            "attribution": ATTRIBUTION,
            "coverage": (
                f"Approved geographical names in {province_name}: lakes, "
                "rivers, bays, rapids and falls, islands, points, shoals and "
                "hills, towns and named localities, parks, conservation "
                "reserves, townships, municipalities and reserves, wetlands "
                "and woods, boat launches, docks and campgrounds."
            ),
            "coverage_incomplete": True,
            "coverage_note": (
                "Names approved by the Geographical Names Board of Canada. A "
                "place with only a local name is not in here, and its absence "
                "is not evidence it does not exist. This is not a road "
                "network: named roads and trails are not searchable."
            ),
            "excluded_types": {
                code: f"{reason} ({dropped.get(code, 0)} records)"
                for code, reason in EXCLUDED_CODES.items()
            },
            "types": types,
            "contexts": contexts,
        },
        # Column-major so a reader decodes a handful of large lists instead of
        # one small list per record. Feature type and county repeat across tens
        # of thousands of records, so both are interned in the metadata above
        # and referenced by index here.
        "names": [record[0] for record in records],
        "type_ids": [type_ids[record[1]] for record in records],
        "context_ids": [context_ids[record[2]] for record in records],
        "lat_e5": [record[3] for record in records],
        "lon_e5": [record[4] for record in records],
    }

    out = ROOT / "data" / province_id / "gazetteer" / "places.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    update_manifest(province_id, out, len(records))

    print(
        f"{province_id}: {len(records)} of {total} CGNDB records -> "
        f"{out.relative_to(ROOT)} ({out.stat().st_size / 1e6:.2f} MB), "
        f"{len(types)} feature types, {len(contexts)} counties"
    )
    for code, count in sorted(dropped.items(), key=lambda item: -item[1]):
        print(f"    dropped {count:6d}  {code}")
    return out


def update_manifest(province_id: str, index_path: Path, record_count: int) -> None:
    manifest_path = ROOT / "data" / province_id / "manifest.json"
    if not manifest_path.is_file():
        print(f"  skip manifest: missing {manifest_path}")
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["gazetteer"] = {
        "label": "Place names",
        "path": index_path.relative_to(index_path.parents[1]).as_posix(),
        "record_count": record_count,
        "source": SOURCE,
        "source_url": f"{SOURCE_URL}{PROVINCES[province_id][1]}.zip",
        "license": LICENSE,
        "license_url": LICENSE_URL,
        "attribution": ATTRIBUTION,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"  declared gazetteer in {manifest_path.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--province",
        choices=(*PROVINCES, "all"),
        default="all",
        help="Which province index to build (default: all)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download the source CSV instead of reusing _tmp_cgndb",
    )
    args = parser.parse_args()

    ids = list(PROVINCES) if args.province == "all" else [args.province]
    for province_id in ids:
        build(province_id, force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
