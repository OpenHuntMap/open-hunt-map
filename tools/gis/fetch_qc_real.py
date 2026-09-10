#!/usr/bin/env python3
"""Fetch real Quebec overlays from open provincial GIS services.

Layers:
  wmu            — Zones de chasse et pêche (GAGQ)
  parks          — Parcs nationaux + réserves + ZEC (TRQ)
  crown_land     — ZECs + exclusive hunting territories on public land
                   (proxy for publicly hunt-relevant Crown tenure until
                   full tenure fabric is wired)
  municipalities — omitted here if StatsCan shapefile unavailable; see
                   fetch_municipalities_qc.py
  municipal_forest — empty real schema (no province-wide municipal forest)

Licenses: Quebec open data / MRNF cartographic services.
"""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.ops import unary_union
from shapely.validation import make_valid

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "data/qc/overlays"

GAGQ_ZONES = (
    "https://peche.faune.gouv.qc.ca/arcgiswa/rest/services/"
    "PRODC-E/GAGQ/MapServer/31/query"
)
TRQ = (
    "https://servicescarto.mrnf.gouv.qc.ca/pes/rest/services/"
    "Territoire/TRQ_WMS/MapServer"
)

# park_type, hunting_allowed, layer bucket
TRQ_LAYERS = {
    # layer_id: (park_type, hunting_allowed, bucket, name_fields)
    4: ("national_park_canada", False, "parks"),
    5: ("national_park_quebec", False, "parks"),
    6: ("regional_park", False, "parks"),
    10: ("wildlife_refuge", False, "parks"),
    11: ("wildlife_reserve", False, "parks"),
    12: ("national_wildlife_area", False, "parks"),
    13: ("ecological_reserve", False, "parks"),
    9: ("migratory_bird_sanctuary", False, "parks"),
    16: ("zec", True, "crown_land"),
    15: ("exclusive_hunting_territory", True, "crown_land"),
    8: ("outfitter_exclusive", True, "crown_land"),
}


def query(url: str, params: dict) -> dict:
    full = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(full, headers={"User-Agent": "OpenWoodsMap/0.1"})
    with urllib.request.urlopen(req, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(text[:200])
    return json.loads(text)


def fetch_layer(url: str, *, simplify: float) -> list[dict]:
    features: list[dict] = []
    offset = 0
    page_size = 1000
    while True:
        params = {
            "where": "1=1",
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson",
            "resultRecordCount": str(page_size),
            "resultOffset": str(offset),
            "maxAllowableOffset": str(simplify),
        }
        page = query(url, params)
        batch = page.get("features") or []
        features.extend(batch)
        print(f"    offset={offset} total={len(features)}", flush=True)
        if len(batch) < page_size:
            break
        offset += page_size
    return features


def feature_name(props: dict, fallback: str) -> str:
    for key in (
        "NOM_OFFICIEL",
        "TRQ_NM_TER",
        "TRQ_DE_IND",
        "DESCRIPTION",
        "NAME",
        "name",
    ):
        value = props.get(key)
        if value:
            return str(value).strip()
    return fallback


def simplify_geom(geom, tol: float):
    g = shape(geom)
    if not g.is_valid:
        g = make_valid(g)
    if tol > 0:
        g = g.simplify(tol, preserve_topology=True)
    if g.is_empty or g.geom_type == "GeometryCollection":
        return None
    return g


def write_fc(path: Path, layer: str, features: list[dict], meta: dict) -> None:
    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "layer": layer,
            "feature_count": len(features),
            "province": "qc",
            **meta,
        },
        "features": features,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    print(f"Wrote {len(features)} -> {path} ({path.stat().st_size/1e6:.2f} MB)")


def build_wmu(simplify: float) -> None:
    print("Fetching QC hunting zones …", flush=True)
    raw = fetch_layer(GAGQ_ZONES, simplify=simplify)
    by_name: dict[str, list] = {}
    for feature in raw:
        props = feature.get("properties") or {}
        name = str(props.get("NM_TSJP") or "").strip()
        if not name or not feature.get("geometry"):
            continue
        g = simplify_geom(feature["geometry"], simplify)
        if g is None:
            continue
        by_name.setdefault(name, []).append(g)
    out = []
    for i, (name, geoms) in enumerate(sorted(by_name.items()), 1):
        merged = unary_union(geoms)
        if not merged.is_valid:
            merged = make_valid(merged)
        if merged.is_empty:
            continue
        out.append(
            {
                "type": "Feature",
                "properties": {
                    "id": f"qc-zone-{i}",
                    "wmu_id": name,
                    "name": f"Zone {name}",
                    "province": "QC",
                    "source": "Québec — Zones de chasse et pêche (GAGQ)",
                    "zone_kind": "zone_de_chasse",
                },
                "geometry": mapping(merged),
            }
        )
    write_fc(
        OUT_DIR / "wmu.geojson",
        "wmu",
        out,
        {
            "coverage": "Quebec hunting/fishing zones (province-wide)",
            "license": "Données ouvertes du Québec",
            "source": GAGQ_ZONES,
        },
    )


def build_trq(simplify: float) -> None:
    parks: list[dict] = []
    crown: list[dict] = []
    for layer_id, (park_type, hunting, bucket) in TRQ_LAYERS.items():
        print(f"Fetching TRQ layer {layer_id} ({park_type}) …", flush=True)
        url = f"{TRQ}/{layer_id}/query"
        try:
            raw = fetch_layer(url, simplify=simplify)
        except Exception as exc:  # noqa: BLE001
            print(f"  skip layer {layer_id}: {exc}")
            continue
        for i, feature in enumerate(raw, 1):
            props = feature.get("properties") or {}
            name = feature_name(props, f"{park_type}-{i}")
            if not feature.get("geometry"):
                continue
            g = simplify_geom(feature["geometry"], simplify)
            if g is None:
                continue
            item = {
                "type": "Feature",
                "properties": {
                    "id": f"qc-trq-{layer_id}-{i}",
                    "name": name,
                    "province": "QC",
                    "park_type": park_type,
                    "designation": park_type.replace("_", " "),
                    "hunting_allowed": hunting,
                    "policy_id": str(
                        props.get("CODE_ADMINISTRATIF")
                        or props.get("TRQ_CO_TER")
                        or props.get("ID")
                        or ""
                    )
                    or None,
                    "summary": (
                        "Structured recreational / wildlife territory on "
                        "Quebec public land. Verify current regulations."
                        if hunting
                        else "Protected or restricted territory — hunting "
                        "generally not permitted; verify regulations."
                    ),
                    "source": f"MRNF TRQ_WMS layer {layer_id}",
                },
                "geometry": mapping(g),
            }
            if bucket == "parks":
                parks.append(item)
            else:
                item["properties"]["layer_role"] = "public_hunt_territory"
                crown.append(item)

    write_fc(
        OUT_DIR / "parks.geojson",
        "parks",
        parks,
        {
            "coverage": "Quebec parks, reserves, refuges (TRQ)",
            "license": "CC-BY 4.0 / Données ouvertes du Québec",
            "source": TRQ,
        },
    )
    write_fc(
        OUT_DIR / "crown_land.geojson",
        "crown_land",
        crown,
        {
            "coverage": (
                "Quebec hunt-relevant public territories (ZEC, exclusive "
                "rights, outfitters) — not full Crown tenure fabric"
            ),
            "license": "CC-BY 4.0 / Données ouvertes du Québec",
            "source": TRQ,
            "note": (
                "Full provincial Crown tenure is a later pack. This layer "
                "shows structured public hunting territories hunters use."
            ),
        },
    )


def build_empty_municipal_forest() -> None:
    write_fc(
        OUT_DIR / "municipal_forest.geojson",
        "municipal_forest",
        [],
        {
            "coverage": "None yet — no province-wide municipal forest layer",
            "license": "n/a",
            "note": "Add municipal open-data extracts city-by-city as available.",
        },
    )


def build_empty_townships() -> None:
    write_fc(
        OUT_DIR / "townships.geojson",
        "townships",
        [],
        {
            "coverage": "Not used — prefer StatsCan CSD municipalities",
            "license": "n/a",
            "note": "Quebec survey cantons are not shipped.",
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simplify", type=float, default=0.002)
    args = parser.parse_args()
    build_wmu(args.simplify)
    build_trq(args.simplify)
    build_empty_municipal_forest()
    build_empty_townships()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
