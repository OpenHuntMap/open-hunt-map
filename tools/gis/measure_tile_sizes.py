"""Measure average tile weights for the offline basemap size estimator.

The estimator in `app/lib/offline/tile_math.dart` multiplies a tile count by a
per-source average. Those averages have to come from the real endpoints rather
than from a guess, so this script samples tiles across settled and bush areas of
Ontario and Quebec and prints the medians to paste back into the Dart constants.

Run it again if a source changes; it is not part of the build.
"""

from __future__ import annotations

import math
import statistics
import sys

import requests

# Spread across the kind of country this app is actually used in: a city, a
# town, farmland, near-north bush and far-north bush. Averaging over only
# Toronto would overstate every pack a hunter downloads.
SAMPLES = [
    ("Toronto", -79.38, 43.65),
    ("Ottawa", -75.70, 45.42),
    ("Peterborough", -78.32, 44.31),
    ("Bancroft bush", -77.85, 45.06),
    ("Algonquin", -78.38, 45.58),
    ("Sudbury", -80.99, 46.49),
    ("Hearst bush", -83.67, 49.69),
    ("Red Lake bush", -93.79, 51.03),
    ("Gatineau", -75.77, 45.55),
    ("Saguenay", -71.07, 48.43),
]

SOURCES = {
    "openfreemap_vector": {
        "template": None,  # resolved from the TileJSON below
        "tilejson": "https://tiles.openfreemap.org/planet",
        "zooms": [8, 10, 12, 14],
    },
    "sentinel2": {
        "template": "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2024_3857"
        "/default/g/{z}/{y}/{x}.jpg",
        "zooms": [8, 10, 12, 14],
    },
    "on_ortho": {
        "template": "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services"
        "/LIO_Imagery/Ontario_Imagery_Web_Map_Service/MapServer/tile/{z}/{y}/{x}",
        "zooms": [10, 12, 14, 16],
    },
    "qc_ortho": {
        "template": "https://servicesmatriciels.mern.gouv.qc.ca/erdas-iws/ogc/wmts"
        "/Imagerie_Continue/Imagerie_GQ/default/GoogleMapsCompatibleExt2:epsg:3857"
        "/{z}/{y}/{x}.jpg",
        "zooms": [10, 12, 14, 16],
    },
}

ONTARIO_ONLY = {"on_ortho"}
QUEBEC_ONLY = {"qc_ortho"}


def tile_xy(lon: float, lat: float, zoom: int) -> tuple[int, int]:
    n = 2**zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return x, y


def in_quebec(lon: float, lat: float) -> bool:
    return lon > -79.9 and lat > 44.9


def sample(name: str, spec: dict) -> None:
    template = spec["template"]
    if template is None:
        meta = requests.get(spec["tilejson"], timeout=30).json()
        template = meta["tiles"][0]
        print(f"  (resolved {name} -> {template})", file=sys.stderr)

    sizes: list[int] = []
    for place, lon, lat in SAMPLES:
        if name in ONTARIO_ONLY and in_quebec(lon, lat):
            continue
        if name in QUEBEC_ONLY and not in_quebec(lon, lat):
            continue
        for zoom in spec["zooms"]:
            x, y = tile_xy(lon, lat, zoom)
            url = template.format(z=zoom, x=x, y=y)
            try:
                response = requests.get(url, timeout=60)
            except requests.RequestException as error:
                print(f"    {place} z{zoom}: {error}", file=sys.stderr)
                continue
            if response.status_code != 200:
                print(
                    f"    {place} z{zoom}: HTTP {response.status_code}",
                    file=sys.stderr,
                )
                continue
            sizes.append(len(response.content))

    if not sizes:
        print(f"{name}: no samples")
        return
    print(
        f"{name}: n={len(sizes)} "
        f"median={statistics.median(sizes) / 1024:.1f} KiB "
        f"mean={statistics.fmean(sizes) / 1024:.1f} KiB "
        f"min={min(sizes) / 1024:.1f} max={max(sizes) / 1024:.1f}"
    )


def main() -> None:
    for name, spec in SOURCES.items():
        print(f"sampling {name}...", file=sys.stderr)
        sample(name, spec)


if __name__ == "__main__":
    main()
