#!/usr/bin/env python3
"""Rebuild Ontario + Quebec *geometry* overlays and optional zip packs.

Does NOT refresh seasons/policies (curated / manual). Those ride along from
whatever is already under data/{province}/seasons and policies/.

Usage:
  python rebuild_geometry.py              # ON + QC overlays
  python rebuild_geometry.py --pack       # also write packs/*.zip
  python rebuild_geometry.py --province on --pack
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GIS = Path(__file__).resolve().parent
CLUPA_ZIP_URL = (
    "https://ws.gisetl.lrc.gov.on.ca/fmedatadownload/Packages/CLUPAPRO.zip"
)
CLUPA_TMP = GIS / "_tmp_clupapro"
CLUPA_ZIP = CLUPA_TMP / "CLUPAPRO.zip"


def run(script: str, *args: str) -> None:
    cmd = [sys.executable, str(GIS / script), *args]
    print(f"\n==> {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, check=True, cwd=str(GIS))


def download_clupapro(*, force: bool = False) -> None:
    CLUPA_TMP.mkdir(parents=True, exist_ok=True)
    have_shp = bool(list(CLUPA_TMP.rglob("CLUPA_PROVINCIAL.shp")))
    if force or not (CLUPA_ZIP.exists() and CLUPA_ZIP.stat().st_size > 1_000_000):
        print(f"Downloading {CLUPA_ZIP_URL} ...", flush=True)
        req = urllib.request.Request(
            CLUPA_ZIP_URL, headers={"User-Agent": "OpenWoodsMap/0.1"}
        )
        with urllib.request.urlopen(req, timeout=600) as response:
            CLUPA_ZIP.write_bytes(response.read())
        print(f"Saved {CLUPA_ZIP} ({CLUPA_ZIP.stat().st_size / 1e6:.1f} MB)", flush=True)
        have_shp = False
    else:
        print(f"Using cached {CLUPA_ZIP}", flush=True)

    if not have_shp:
        print(f"Extracting {CLUPA_ZIP.name} ...", flush=True)
        with zipfile.ZipFile(CLUPA_ZIP) as archive:
            archive.extractall(CLUPA_TMP)


def stamp_manifest(province_id: str) -> None:
    """Refresh feature_count from overlay files and set generated_at."""
    province = ROOT / "data" / province_id
    manifest_path = province / "manifest.json"
    if not manifest_path.is_file():
        print(f"skip manifest stamp: missing {manifest_path}", flush=True)
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest["generated_at"] = now
    for layer in manifest.get("layers") or []:
        rel = layer.get("path")
        if not rel:
            continue
        geo_path = province / rel
        if not geo_path.is_file():
            continue
        data = json.loads(geo_path.read_text(encoding="utf-8"))
        layer["feature_count"] = len(data.get("features") or [])
        meta = data.get("metadata") or {}
        if meta.get("coverage") and not layer.get("coverage"):
            layer["coverage"] = meta["coverage"]
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Stamped {manifest_path} generated_at={now}", flush=True)


def rebuild_on(*, skip_clupa_download: bool) -> None:
    # Legal text first: parks read their hunting permission from O. Reg. 663/98
    # Part 3, and the Sunday gun overlay is built from Part 7 of the same
    # regulation. Without this the parks layer cannot state a permission.
    run("parse_reg663_on.py")
    # The Act behind the regulation. It carries the one Algonquin opening the
    # regulation does not, and the subsection that makes a conservation reserve
    # open by default, so both the parks and reserve layers read from it.
    run("parse_ppcra_on.py")
    # Federal closures read their prohibitions from the Justice Laws
    # consolidation, so the rules are parsed before the geometry is attributed.
    run("parse_federal_wildlife_regs.py")
    # parks must exist before crown so protected parcels can be flagged
    run("fetch_wmu_parks_on.py")
    run("fetch_conservation_reserve_on.py")
    run("fetch_municipalities_on.py")
    # Needs municipalities and townships, so it runs after both
    run("fetch_townships_on.py")
    # The divide has to exist before the schedule is assembled, because the
    # Sunday gun layer appends it. Without it the layer still builds and still
    # looks right, but every point north of the French and Mattawa rivers loses
    # its answer and reads as a prohibition.
    run("build_sunday_divide_on.py")
    run("build_sunday_gun_on.py")
    # Public forest tracts (county/regional/municipal) at parcel level
    run("fetch_agreement_forest_on.py")
    # Closures drawn over the tenure layers (FWCA s. 9)
    run("fetch_game_preserve_on.py")
    # Conservation authority land and the federal closures, both from CPCAD
    run("fetch_cpcad_on.py")
    # Land an Ontario licence does not reach, from the two federal registers
    run("fetch_first_nations_on.py")
    run("fetch_defence_land_on.py")
    # Context for the Far North, where the policy atlas runs out
    run("fetch_land_use_plan_on.py")
    download_clupapro(force=not skip_clupa_download)
    run("fetch_unpatented_on.py")
    # Build-time only, and nothing from it ships: Ontario's tenure record covers
    # lake beds, so without this the card in the middle of open water is the card
    # for dry ground.
    run("fetch_hydrography_on.py")
    # Crown tenure parcels + CLUPA designation/permitted-use attributes
    run("build_crown_on.py")
    # Who else occupies that tenure. Half of it carries no land use policy, so
    # without this a leased hunt camp is drawn as ordinary open Crown land.
    run("fetch_dispositions_on.py")
    # Official policy text keyed by the policy_id carried on those parcels
    run("build_policies_on.py")
    # Point data rather than geometry, but it is a per-province source fetch and
    # the pack is incomplete without it
    run("fetch_cgndb.py", "--province", "on")
    stamp_manifest("on")


def rebuild_qc() -> None:
    run("fetch_qc_real.py")
    run("fetch_municipalities_qc.py")
    run("fetch_cgndb.py", "--province", "qc")
    stamp_manifest("qc")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--province",
        choices=("on", "qc", "all"),
        default="all",
        help="Which province geometry to rebuild (default: all)",
    )
    parser.add_argument(
        "--pack",
        action="store_true",
        help="Build packs/{id}-overlays.zip after overlays refresh",
    )
    parser.add_argument(
        "--skip-clupa-download",
        action="store_true",
        help="Reuse existing CLUPAPRO zip/extract under _tmp_clupapro (ON)",
    )
    parser.add_argument(
        "--skip-audit",
        action="store_true",
        help="Skip the pre-pack audit (for iterating on one script, not for CI)",
    )
    args = parser.parse_args()

    try:
        if args.province in ("on", "all"):
            rebuild_on(skip_clupa_download=args.skip_clupa_download)
        if args.province in ("qc", "all"):
            rebuild_qc()
        # Before anything is packaged, not after. Every check in the audit exists
        # because the build scripts once produced the thing it looks for from
        # sound upstream data, so a rebuild is exactly the moment it can come
        # back — and the pack is what reaches phones.
        if not args.skip_audit:
            run("audit_overlays.py", "--province", args.province)
        if args.pack:
            provinces = (
                ["on", "qc"] if args.province == "all" else [args.province]
            )
            run("build_pack.py", *provinces)
    except subprocess.CalledProcessError as exc:
        print(f"Command failed with exit {exc.returncode}", file=sys.stderr)
        return exc.returncode or 1
    print("\nGeometry rebuild complete.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
