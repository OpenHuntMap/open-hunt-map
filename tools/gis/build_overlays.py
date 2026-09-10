#!/usr/bin/env python3
"""
Validate and repack province overlay GeoJSON, or fetch from open-data sources.

Zero-infra: reads public URLs from sources_{province}.json; when downloads are
unavailable, normalizes existing sample files under data/{province}/overlays/.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from shapely.geometry import shape
from shapely.validation import explain_validity

from enrich_land_info import enrich_collection

CRS_WGS84 = "EPSG:4326"
SUPPORTED_PROVINCES = ("on", "qc")

LAYER_DEFAULTS: dict[str, dict[str, Any]] = {
    "crown_land": {"type": "crown_land", "province_key": "province"},
    "wmu": {"type": "wmu", "province_key": "province"},
    "parks": {"type": "park", "province_key": None},
    "townships": {"type": "geographic_township", "province_key": "province"},
    "municipalities": {"type": "municipality", "province_key": "province"},
    "municipal_forest": {"type": "municipal_forest", "province_key": None},
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_sources(province: str) -> dict:
    path = Path(__file__).resolve().parent / f"sources_{province}.json"
    if not path.is_file():
        raise FileNotFoundError(f"Source registry not found: {path}")
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def try_download(url: str | None, timeout: int = 30) -> bytes | None:
    if not url:
        return None
    try:
        resp = requests.get(url, timeout=timeout, headers={"User-Agent": "OpenWoodsMap-GIS/0.1"})
        resp.raise_for_status()
        return resp.content
    except requests.RequestException as exc:
        print(f"  download skipped ({exc.__class__.__name__}): {url}")
        return None


def validate_geometry(geom: dict) -> list[str]:
    issues: list[str] = []
    try:
        geom_obj = shape(geom)
    except Exception as exc:  # noqa: BLE001 — report all geometry parse errors
        return [f"invalid geometry: {exc}"]

    if not geom_obj.is_valid:
        issues.append(explain_validity(geom_obj))

    bounds = geom_obj.bounds
    if bounds[0] < -180 or bounds[2] > 180 or bounds[1] < -90 or bounds[3] > 90:
        issues.append(
            f"coordinates outside WGS84 range (minx={bounds[0]}, miny={bounds[1]})"
        )
    return issues


def apply_layer_defaults(layer_id: str, props: dict, province: str) -> dict:
    out = dict(props)
    defaults = LAYER_DEFAULTS.get(layer_id, {})

    if defaults.get("province_key") and not out.get(defaults["province_key"]):
        out[defaults["province_key"]] = province.upper()

    if layer_id == "townships" and not out.get("type"):
        out["type"] = defaults.get("type", "geographic_township")

    if layer_id == "municipalities" and not out.get("type"):
        out["type"] = defaults.get("type", "municipality")

    return out


def validate_feature(
    feature: dict,
    layer_id: str,
    required: list[str],
    province: str,
    index: int,
) -> tuple[dict | None, list[str]]:
    warnings: list[str] = []

    if feature.get("type") != "Feature":
        return None, [f"feature[{index}]: not a Feature"]

    props = apply_layer_defaults(layer_id, feature.get("properties") or {}, province)
    geom = feature.get("geometry")
    if not geom:
        return None, [f"feature[{index}]: missing geometry"]

    geom_issues = validate_geometry(geom)
    warnings.extend(f"feature[{index}]: {msg}" for msg in geom_issues)

    missing = [key for key in required if props.get(key) in (None, "")]
    if missing:
        warnings.append(f"feature[{index}]: missing properties {missing}")

    return {**feature, "properties": props}, warnings


def normalize_collection(
    data: dict,
    layer_id: str,
    required: list[str],
    province: str,
    sources_cfg: dict,
) -> tuple[dict, list[str]]:
    all_warnings: list[str] = []
    normalized_features: list[dict] = []

    for idx, feature in enumerate(data.get("features", [])):
        normalized, warnings = validate_feature(
            feature, layer_id, required, province, idx
        )
        all_warnings.extend(warnings)
        if normalized is not None:
            normalized_features.append(normalized)

    if layer_id == "crown_land":
        base = {
            **data,
            "type": "FeatureCollection",
            "features": normalized_features,
        }
        enriched, _ = enrich_collection(base)
        normalized_features = enriched["features"]

    metadata = {
        "crs": CRS_WGS84,
        "province": province,
        "layer": layer_id,
        "feature_count": len(normalized_features),
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "tools/gis/build_overlays.py",
        "license": sources_cfg.get("license"),
        "license_url": sources_cfg.get("license_url"),
        "attribution": sources_cfg.get("attribution"),
    }

    return {
        "type": "FeatureCollection",
        "metadata": metadata,
        "features": normalized_features,
    }, all_warnings


def load_existing_geojson(path: Path) -> dict | None:
    if not path.is_file():
        return None
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def write_geojson(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def build_manifest(
    sources_cfg: dict,
    layer_results: list[dict],
    version: str,
) -> dict:
    layers = []
    for result in layer_results:
        layers.append(
            {
                "id": result["id"],
                "label": result["label"],
                "path": result["path"],
                "format": "geojson",
                "feature_count": result["feature_count"],
                "crs": CRS_WGS84,
            }
        )

    return {
        "id": sources_cfg["province"],
        "name": sources_cfg["name"],
        "version": version,
        "crs": CRS_WGS84,
        "license": sources_cfg.get("license"),
        "license_url": sources_cfg.get("license_url"),
        "layers": layers,
        "policies": "policies/",
    }


def safe_print(text: str) -> None:
    """Print without crashing on Windows cp1252 consoles."""
    try:
        print(text)
    except UnicodeEncodeError:
        print(text.encode(sys.stdout.encoding or "utf-8", errors="replace").decode(
            sys.stdout.encoding or "utf-8", errors="replace"
        ))


def print_fetch_plan(sources_cfg: dict) -> None:
    safe_print("\n--- Full provincial fetch plan (when online) ---")
    safe_print(
        f"License: {sources_cfg.get('license')} ({sources_cfg.get('license_url')})"
    )
    for layer_id, layer in sources_cfg.get("layers", {}).items():
        safe_print(f"\n[{layer_id}] {layer.get('label')}")
        safe_print(f"  output: data/{sources_cfg['province']}/{layer.get('output')}")
        for src in layer.get("sources", []):
            safe_print(f"  - {src.get('name')} ({src.get('format')})")
            safe_print(f"    portal: {src.get('portal')}")
            safe_print(f"    url:    {src.get('url')}")
            if src.get("download"):
                safe_print(f"    fetch:  {src.get('download')}")
            if src.get("notes"):
                safe_print(f"    notes:  {src.get('notes')}")


def process_layer(
    layer_id: str,
    layer_cfg: dict,
    province: str,
    data_dir: Path,
    sources_cfg: dict,
    attempt_download: bool,
) -> dict:
    rel_output = layer_cfg["output"]
    output_path = data_dir / rel_output
    required = layer_cfg.get("required_properties", [])

    downloaded = False
    if attempt_download:
        for src in layer_cfg.get("sources", []):
            content = try_download(src.get("download"))
            if content:
                print(f"  downloaded {len(content)} bytes from {src.get('name')}")
                downloaded = True
                # Full ingest (shapefile zip, ArcGIS REST, etc.) is future work.
                break

    if not downloaded:
        print(f"  using existing sample: {output_path}")

    raw = load_existing_geojson(output_path)
    if raw is None:
        raise FileNotFoundError(
            f"No GeoJSON at {output_path} and download unavailable. "
            f"Add a sample file or connect to fetch sources."
        )

    normalized, warnings = normalize_collection(
        raw, layer_id, required, province, sources_cfg
    )
    write_geojson(output_path, normalized)

    for warning in warnings:
        print(f"  warn: {warning}")

    print(
        f"  wrote {output_path.relative_to(repo_root())} "
        f"({normalized['metadata']['feature_count']} features, {CRS_WGS84})"
    )

    return {
        "id": layer_id,
        "label": layer_cfg.get("label", layer_id),
        "path": rel_output.replace("\\", "/"),
        "feature_count": normalized["metadata"]["feature_count"],
        "warnings": len(warnings),
    }


def run(province: str, version: str, attempt_download: bool) -> int:
    province = province.lower()
    if province not in SUPPORTED_PROVINCES:
        print(
            f"error: unsupported province '{province}'. "
            f"Supported: {', '.join(SUPPORTED_PROVINCES)}",
            file=sys.stderr,
        )
        return 1

    sources_cfg = load_sources(province)
    data_dir = repo_root() / "data" / province

    if not data_dir.is_dir():
        print(f"error: data directory not found: {data_dir}", file=sys.stderr)
        return 1

    print(f"Building overlays for {sources_cfg['name']} ({province})")
    print(f"Data directory: {data_dir}")

    layer_results: list[dict] = []
    for layer_id, layer_cfg in sources_cfg.get("layers", {}).items():
        print(f"\nLayer: {layer_id}")
        try:
            result = process_layer(
                layer_id,
                layer_cfg,
                province,
                data_dir,
                sources_cfg,
                attempt_download,
            )
            layer_results.append(result)
        except FileNotFoundError as exc:
            print(f"  error: {exc}", file=sys.stderr)
            return 1

    manifest = build_manifest(sources_cfg, layer_results, version)
    manifest_path = data_dir / "manifest.json"
    with manifest_path.open("w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"\nWrote manifest: {manifest_path.relative_to(repo_root())}")
    print_fetch_plan(sources_cfg)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build or validate province overlay GeoJSON packs."
    )
    parser.add_argument(
        "--province",
        required=True,
        help="Province code (on, qc)",
    )
    parser.add_argument(
        "--version",
        default="0.0.0",
        help="Pack version written to manifest.json (default: 0.0.0)",
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="Attempt to download from source registry URLs before repacking",
    )
    args = parser.parse_args(argv)
    return run(args.province, args.version, args.download)


if __name__ == "__main__":
    raise SystemExit(main())
