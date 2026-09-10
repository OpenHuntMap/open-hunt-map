#!/usr/bin/env python3
"""Fill CLUPA gaps by re-querying failed tiles with retries + subdivision.

Merges into existing data/on/overlays/crown_land.geojson by policy_id.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from shapely.geometry import mapping, shape
from shapely.validation import make_valid

# Reuse helpers from fetch_clupa_on
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_clupa_on import (  # noqa: E402
    LAYER_URL,
    ON_BBOX,
    PAGE_SIZE,
    normalize,
)

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/overlays/crown_land.geojson"


def _query(params: dict) -> dict:
    url = f"{LAYER_URL}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "OpenWoodsMap/0.2 (gap-fill)"})
    with urllib.request.urlopen(req, timeout=300) as response:
        text = response.read().decode("utf-8", errors="replace").strip()
    if not text or text[0] not in "{[":
        raise ValueError(f"Non-JSON ({len(text)} chars)")
    return json.loads(text)


def fetch_bbox_once(bbox: tuple[float, float, float, float]) -> list[dict]:
    xmin, ymin, xmax, ymax = bbox
    features: list[dict] = []
    offset = 0
    while True:
        params = {
            "where": "1=1",
            "geometry": f"{xmin},{ymin},{xmax},{ymax}",
            "geometryType": "esriGeometryEnvelope",
            "inSR": "4326",
            "spatialRel": "esriSpatialRelIntersects",
            "outFields": "POLICY_IDENT,NAME_ENG,DESIGNATION_ENG,CATEGORY_ENG",
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson",
            "resultRecordCount": str(PAGE_SIZE),
            "resultOffset": str(offset),
            "maxAllowableOffset": "0.001",
        }
        page = _query(params)
        if page.get("error"):
            raise RuntimeError(page["error"])
        batch = page.get("features") or []
        features.extend(batch)
        if len(batch) < PAGE_SIZE:
            break
        offset += PAGE_SIZE
    return features


def fetch_bbox_with_retries(
    bbox: tuple[float, float, float, float],
    *,
    retries: int = 4,
    label: str = "",
) -> list[dict]:
    delay = 2.0
    last_exc: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            feats = fetch_bbox_once(bbox)
            print(f"  OK {label} -> {len(feats)} (attempt {attempt})", flush=True)
            return feats
        except (ValueError, urllib.error.URLError, TimeoutError, RuntimeError) as exc:
            last_exc = exc
            print(f"  FAIL {label} attempt {attempt}/{retries}: {exc}", flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 30)
    raise RuntimeError(f"Tile failed after retries: {label}: {last_exc}")


def fetch_adaptive(
    bbox: tuple[float, float, float, float],
    *,
    depth: int = 0,
    max_depth: int = 3,
    label: str = "root",
) -> list[dict]:
    """Fetch a bbox; on persistent failure, split into 4 and recurse."""
    try:
        return fetch_bbox_with_retries(bbox, label=label)
    except RuntimeError:
        if depth >= max_depth:
            print(f"  GIVE UP {label}", flush=True)
            return []
        xmin, ymin, xmax, ymax = bbox
        mx = (xmin + xmax) / 2
        my = (ymin + ymax) / 2
        children = [
            (xmin, ymin, mx, my),
            (mx, ymin, xmax, my),
            (xmin, my, mx, ymax),
            (mx, my, xmax, ymax),
        ]
        out: list[dict] = []
        for i, child in enumerate(children):
            out.extend(
                fetch_adaptive(
                    child,
                    depth=depth + 1,
                    max_depth=max_depth,
                    label=f"{label}.{i}",
                )
            )
            time.sleep(0.5)
        return out


def merge(existing: list[dict], incoming: list[dict]) -> list[dict]:
    seen = {
        f.get("properties", {}).get("policy_id")
        for f in existing
        if f.get("properties", {}).get("policy_id")
    }
    added = 0
    for feature in incoming:
        pid = feature.get("properties", {}).get("policy_id")
        if not pid or pid in seen:
            continue
        seen.add(pid)
        existing.append(feature)
        added += 1
    print(f"Merged +{added} new policies (total {len(existing)})", flush=True)
    return existing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tiles", type=int, default=8, help="Initial grid size")
    parser.add_argument("--simplify", type=float, default=0.002)
    parser.add_argument("--max-depth", type=int, default=3)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    existing_payload = {"type": "FeatureCollection", "features": []}
    if args.out.exists():
        existing_payload = json.loads(args.out.read_text(encoding="utf-8"))
    existing = existing_payload.get("features") or []
    print(f"Starting with {len(existing)} features", flush=True)

    xmin, ymin, xmax, ymax = ON_BBOX
    cols = rows = args.tiles
    width = (xmax - xmin) / cols
    height = (ymax - ymin) / rows

    raw: list[dict] = []
    for row in range(rows):
        for col in range(cols):
            tile = (
                xmin + col * width,
                ymin + row * height,
                xmin + (col + 1) * width,
                ymin + (row + 1) * height,
            )
            label = f"r{row}c{col}"
            print(f"Tile {label}: {tile}", flush=True)
            raw.extend(
                fetch_adaptive(tile, max_depth=args.max_depth, label=label)
            )
            time.sleep(0.75)

    print(f"Normalizing {len(raw)} raw features...", flush=True)
    normalized = normalize(raw, args.simplify)
    merged = merge(existing, normalized)

    payload = {
        "type": "FeatureCollection",
        "metadata": {
            "crs": "EPSG:4326",
            "province": "on",
            "layer": "crown_land",
            "feature_count": len(merged),
            "coverage": (
                f"Ontario CLUPA Provincial gap-fill "
                f"({args.tiles}x{args.tiles} + adaptive splits)"
            ),
            "license": "OGL-Ontario",
            "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
            "source": "LIO Open06 MapServer layer 5 (CLUPA Provincial)",
        },
        "features": merged,
    }
    args.out.write_text(json.dumps(payload), encoding="utf-8")
    mb = args.out.stat().st_size / (1024 * 1024)
    print(f"Wrote {len(merged)} -> {args.out} ({mb:.2f} MiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
