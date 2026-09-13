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


def build_pack(province_id: str) -> dict[str, object]:
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
    # Exactly the overlays the manifest names, rather than everything sitting in
    # the directory. The manifest is where a layer's source and licence are
    # recorded and therefore where it is vetted, so the manifest is what decides
    # whether it ships. A glob decides on the basis of a file having been written,
    # which is how Quebec's unlicensed hunting zones once reached a published
    # pack, and it also carries build intermediates the app can never draw.
    packed_overlays = {(source / layer["path"]).resolve() for layer in layers}
    files.extend(sorted(packed_overlays))
    skipped = sorted(
        path.relative_to(source).as_posix()
        for path in overlays.rglob("*.geojson")
        if path.is_file() and path.resolve() not in packed_overlays
    )
    if skipped:
        # Printed rather than warned about: some of these are meant to be here.
        # Ontario's sunday_gun_north is the corridor the Sunday gun layer is
        # assembled from, and Quebec's townships is an empty placeholder that
        # records a decision not to ship survey cantons.
        print(f"  not in the manifest, not packed: {', '.join(skipped)}")

    # These three stay directory-driven, because unlike layers they are not
    # enumerated anywhere. Policies are looked up by the policy_id on a feature,
    # and seasons by regulation year, so the manifest names the directory and one
    # current file rather than the full contents.
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
    return {
        "id": province_id,
        "file": output.name,
        "bytes": output.stat().st_size,
        "built": stamped["built"],
        "content_id": stamped["content_id"],
        "version": stamped.get("version", "unknown"),
    }


def write_index(entries: list[dict[str, object]]) -> Path:
    """Publish what is in each pack, small enough for a phone to read on a whim.

    The app has to answer "is there newer data than mine" without downloading
    tens of megabytes to find out, so the answer lives in its own file next to
    the packs. Existing entries are merged rather than replaced: building one
    province must not erase what is published for another, which is easy to do
    because provinces are usually rebuilt one at a time.
    """
    index_path = REPOSITORY_ROOT / "packs" / "packs.json"
    packs: dict[str, object] = {}
    if index_path.is_file():
        try:
            packs = json.loads(index_path.read_text(encoding="utf-8")).get("packs") or {}
        except json.JSONDecodeError:
            # A corrupt index is worth losing rather than propagating; the next
            # build of each province restores its entry.
            packs = {}
    for entry in entries:
        packs[str(entry["id"])] = {k: v for k, v in entry.items() if k != "id"}
    index_path.write_text(
        json.dumps({"packs": packs}, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {index_path.relative_to(REPOSITORY_ROOT)} ({', '.join(sorted(packs))})")
    return index_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("province", nargs="+", help="Province IDs, for example: on qc")
    args = parser.parse_args()
    write_index([build_pack(province_id) for province_id in args.province])


if __name__ == "__main__":
    main()
