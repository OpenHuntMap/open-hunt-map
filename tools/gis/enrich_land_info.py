#!/usr/bin/env python3
"""Ensure crown_land features have Land Info attributes (policy_id, summary)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Default summaries when designation is known but summary is missing.
DESIGNATION_TEMPLATES: dict[str, str] = {
    "General Use Area": (
        "Crown land designated General Use. Hunting may be permitted under "
        "provincial seasons and regulations; verify WMU and local restrictions."
    ),
    "Enhanced Management Area": (
        "Enhanced Management Area with active forest management. Hunting may be "
        "conditional — check posted operational zones and on-site signage."
    ),
    "Wilderness Area": (
        "Wilderness Area with limited access. Hunting rules vary; confirm with "
        "provincial regulations and local notices."
    ),
    # The opposite of a park, not a milder version of one. Provincial Parks and
    # Conservation Reserves Act, 2006, s. 15 (3) permits hunting in a
    # conservation reserve unless a regulation under the Fish and Wildlife
    # Conservation Act, 1997 prohibits it, and s. 12 (3) stops a management plan
    # narrowing that. This template said the reverse.
    "Conservation Reserve": (
        "Conservation Reserve. Hunting is permitted unless a regulation under "
        "the Fish and Wildlife Conservation Act, 1997 prohibits it, such as a "
        "Crown game preserve; confirm posted notices on site."
    ),
    "Provincial Park": (
        "Provincial park boundary. Hunting is generally prohibited inside park "
        "limits unless explicitly allowed for a zone."
    ),
}

DEFAULT_SUMMARY = (
    "Crown land parcel. Confirm land use designation, WMU, and hunting "
    "regulations before hunting."
)

DEFAULT_POLICY_ID = "UNKNOWN"


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def summary_for_designation(designation: str | None) -> str:
    if not designation:
        return DEFAULT_SUMMARY
    return DESIGNATION_TEMPLATES.get(designation.strip(), DEFAULT_SUMMARY)


def enrich_feature(props: dict) -> tuple[dict, list[str]]:
    """Return enriched properties and list of changes made."""
    changes: list[str] = []
    out = dict(props)

    if not out.get("policy_id"):
        out["policy_id"] = DEFAULT_POLICY_ID
        changes.append("filled policy_id")

    designation = out.get("designation")
    if not out.get("summary"):
        out["summary"] = summary_for_designation(
            designation if isinstance(designation, str) else None
        )
        changes.append("filled summary from designation template")

    if "hunting_allowed" not in out:
        out["hunting_allowed"] = "unknown"
        changes.append("set hunting_allowed=unknown")

    if not out.get("designation"):
        out["designation"] = "Unknown"
        changes.append("filled designation")

    return out, changes


def enrich_collection(data: dict) -> tuple[dict, int]:
    features = data.get("features", [])
    change_count = 0
    enriched_features = []

    for feature in features:
        if feature.get("type") != "Feature":
            enriched_features.append(feature)
            continue
        props = feature.get("properties") or {}
        new_props, changes = enrich_feature(props)
        if changes:
            change_count += 1
        enriched_features.append({**feature, "properties": new_props})

    metadata = dict(data.get("metadata") or {})
    metadata["land_info_enriched"] = True

    return {
        **data,
        "metadata": metadata,
        "features": enriched_features,
    }, change_count


def enrich_file(path: Path, dry_run: bool = False) -> int:
    if not path.is_file():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 1

    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)

    if data.get("type") != "FeatureCollection":
        print(f"error: expected FeatureCollection in {path}", file=sys.stderr)
        return 1

    enriched, change_count = enrich_collection(data)
    print(f"{path.name}: enriched {change_count} feature(s)")

    if dry_run:
        print("  (dry run — not writing)")
        return 0

    with path.open("w", encoding="utf-8") as fh:
        json.dump(enriched, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Ensure crown_land GeoJSON has policy_id and summary fields."
    )
    parser.add_argument(
        "--province",
        required=True,
        help="Province code (e.g. on, qc)",
    )
    parser.add_argument(
        "--input",
        type=Path,
        help="Override crown_land.geojson path",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report changes without writing",
    )
    args = parser.parse_args(argv)

    province = args.province.lower()
    path = args.input or (
        repo_root() / "data" / province / "overlays" / "crown_land.geojson"
    )
    return enrich_file(path, dry_run=args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
