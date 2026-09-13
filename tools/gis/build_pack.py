#!/usr/bin/env python3
"""Build a static OpenWoodsMap province overlay pack."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
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


def content_id(files: list[Path], source: Path, manifest_bytes: bytes) -> str:
    """A digest of what the pack contains, ignoring when it was built.

    The app needs to answer "is there newer data than mine", and a build
    timestamp cannot answer it: a scheduled rebuild of unchanged sources produces
    a new timestamp and identical data, which would offer every user an update
    that is only a new date. Hashing the contents means "up to date" survives a
    rebuild.

    The manifest is hashed as it exists on disk rather than as it is written into
    the pack, because the copy in the pack carries this digest and cannot
    contain a hash of itself. Hashing the source keeps manifest-only edits, such
    as a changed note or a dropped layer, inside the comparison.
    """
    digest = hashlib.sha256()
    for path in sorted(files):
        relative = path.relative_to(source).as_posix()
        blob = manifest_bytes if relative == "manifest.json" else path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(blob).digest())
    # Truncated because this is compared for equality and shown in logs, never
    # used as a security boundary. 16 hex characters is 64 bits.
    return digest.hexdigest()[:16]


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

    manifest_bytes = manifest.read_bytes()
    stamped = json.loads(manifest_bytes.decode("utf-8"))
    stamped["content_id"] = content_id(files, source, manifest_bytes)
    # Seconds, and UTC: the app shows this as a date, and a phone in Ontario
    # rendering a Quebec pack should not see the day shift under it.
    stamped["built"] = (
        datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )

    output = REPOSITORY_ROOT / "packs" / f"{province_id}-overlays.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for file_path in sorted(files):
            relative = file_path.relative_to(source).as_posix()
            # The stamp goes into the packed copy only. Writing it back to
            # data/{cc}/manifest.json would put a new timestamp in a tracked file
            # on every build, so the diff of a rebuild would never be empty even
            # when nothing about the province changed.
            if relative == "manifest.json":
                archive.writestr(relative, json.dumps(stamped, ensure_ascii=False, indent=2))
            else:
                archive.write(file_path, relative)

    print(
        f"Built {output.relative_to(REPOSITORY_ROOT)} "
        f"({format_size(output.stat().st_size)}, content {stamped['content_id']})"
    )
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("province", nargs="+", help="Province IDs, for example: on qc")
    args = parser.parse_args()
    for province_id in args.province:
        build_pack(province_id)


if __name__ == "__main__":
    main()
