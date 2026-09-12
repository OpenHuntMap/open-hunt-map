#!/usr/bin/env python3
"""Build a static OpenWoodsMap province overlay pack."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def format_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}"
        value /= 1024
    raise AssertionError("unreachable")


def build_pack(province_id: str) -> Path:
    province_id = province_id.strip().lower()
    source = REPOSITORY_ROOT / "data" / province_id
    manifest = source / "manifest.json"
    overlays = source / "overlays"
    if not manifest.is_file():
        raise FileNotFoundError(f"Missing manifest: {manifest}")
    if not overlays.is_dir():
        raise FileNotFoundError(f"Missing overlays directory: {overlays}")

    # The large overlays are not tracked in git, so a fresh clone can otherwise
    # build a pack the app will reject at install time. Fail here instead.
    layers = json.loads(manifest.read_text(encoding="utf-8")).get("layers") or []
    missing = [
        layer["path"]
        for layer in layers
        if layer.get("path") and not (source / layer["path"]).is_file()
    ]
    if missing:
        raise FileNotFoundError(
            f"{province_id}: manifest references overlays that are not present: "
            f"{', '.join(missing)}\n"
            f"Rebuild them first: python rebuild_geometry.py --province {province_id}"
        )

    files = [manifest]
    files.extend(
        path
        for path in overlays.rglob("*.geojson")
        if path.is_file() and ".clupa_full." not in path.name
    )
    policies = source / "policies"
    if policies.is_dir():
        files.extend(path for path in policies.rglob("*") if path.is_file())
    seasons = source / "seasons"
    if seasons.is_dir():
        files.extend(path for path in seasons.rglob("*.json") if path.is_file())
    # Absent until fetch_cgndb.py has run. A pack without it still installs and
    # still draws the province; the app reports that it carries no place names.
    gazetteer = source / "gazetteer"
    if gazetteer.is_dir():
        files.extend(path for path in gazetteer.rglob("*.json") if path.is_file())

    output = REPOSITORY_ROOT / "packs" / f"{province_id}-overlays.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for file_path in sorted(files):
            archive.write(file_path, file_path.relative_to(source).as_posix())

    print(f"Built {output.relative_to(REPOSITORY_ROOT)} ({format_size(output.stat().st_size)})")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("province", nargs="+", help="Province IDs, for example: on qc")
    args = parser.parse_args()
    for province_id in args.province:
        build_pack(province_id)


if __name__ == "__main__":
    main()
