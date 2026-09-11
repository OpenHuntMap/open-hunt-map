"""Emit UTM -> WGS84 reference values for the Dart parser's tests.

The Dart side implements the inverse transverse Mercator by hand, so its tests
need reference values from something authoritative rather than from the same
arithmetic being tested. pyproj is EPSG-backed, so these are the answers PROJ
gives; the Dart test asserts against them to under a metre.
"""

from pyproj import CRS, Transformer

# Zones 15 to 19 span Ontario and Quebec, plus one southern-hemisphere case to
# exercise the 10,000,000 m false northing.
CASES = [
    (18, "north", 439000.0, 4991000.0),
    (18, "north", 500000.0, 5000000.0),
    (17, "north", 612345.0, 5432109.0),
    (16, "north", 400000.0, 5600000.0),
    (15, "north", 700000.0, 5800000.0),
    (19, "north", 300000.0, 5200000.0),
    (18, "south", 500000.0, 9000000.0),
]

print(f"{'zone':>5} {'hemi':>6} {'easting':>12} {'northing':>12}  lat, lon")
for zone, hemisphere, easting, northing in CASES:
    crs = CRS.from_dict(
        {
            "proj": "utm",
            "zone": zone,
            "south": hemisphere == "south",
            "ellps": "WGS84",
        }
    )
    to_wgs84 = Transformer.from_crs(crs, CRS.from_epsg(4326), always_xy=True)
    lon, lat = to_wgs84.transform(easting, northing)
    print(
        f"{zone:>5} {hemisphere:>6} {easting:>12.1f} {northing:>12.1f}  "
        f"{lat!r}, {lon!r}"
    )
