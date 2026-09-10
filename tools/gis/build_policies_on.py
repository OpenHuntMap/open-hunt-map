#!/usr/bin/env python3
"""Generate Ontario policy markdown from the official CLUPA package.

Replaces hand-written sample policy files with verbatim text published in
the Crown Land Use Policy Atlas download (CLUPAPRO.zip):

  CLUPA_POLICY.csv                     land area, land use intent, prefaces
  CLUPA_POLICY_AND_PERMITTED_USE.csv   per-use permitted flags + guidelines

Writes data/on/policies/{POLICY_IDENT}.md, keyed so the Land Info sheet can
open the policy for any CLUPA-derived feature.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from urllib.parse import quote

csv.field_size_limit(10_000_000)

ROOT = Path(__file__).resolve().parents[2]
CLUPA_TMP = Path(__file__).resolve().parent / "_tmp_clupapro"
OUT_DIR = ROOT / "data/on/policies"

ATLAS_HINT = (
    "https://www.ontario.ca/page/crown-land-use-policy-atlas"
)

# The URL_ENG column still points at crownlanduseatlas.mnr.gov.on.ca, which now
# 302s to a generic landing page and loses the policy. This is the live report
# endpoint, the same one Ontario's own CLUPA map service hyperlinks to.
REPORT_URL = (
    "https://www.lioapplications.lrc.gov.on.ca/services/CLUPA/xmlReader.aspx"
    "?xsl=web-primary.xsl&type=primary&POLICY_IDENT={ident}"
)


def report_url(ident: str) -> str:
    return REPORT_URL.format(ident=quote(ident, safe=""))


def find_csv(name: str) -> Path:
    matches = list(CLUPA_TMP.rglob(name))
    if not matches:
        raise FileNotFoundError(
            f"{name} not found under {CLUPA_TMP}. "
            "Run rebuild_geometry.py (it downloads/extracts CLUPAPRO.zip)."
        )
    return matches[0]


def read_rows(path: Path) -> tuple[list[str], list[list[str]]]:
    with path.open(encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.reader(handle, delimiter=";")
        header = next(reader)
        rows = [row for row in reader if len(row) >= len(header)]
    return header, rows


def fmt_date(raw: str) -> str:
    raw = (raw or "").strip()
    if len(raw) >= 8 and raw[:8].isdigit():
        return f"{raw[0:4]}-{raw[4:6]}-{raw[6:8]}"
    return ""


def clean(text: str) -> str:
    return " ".join((text or "").replace("\r", " ").split()).strip()


def md_escape(text: str) -> str:
    return clean(text).replace("|", "\\|")


def policy_names() -> dict[str, str]:
    """POL_IDENT -> NAME_ENG / DESIG_ENG from the CLUPA shapefile, if present."""
    try:
        import shapefile  # pyshp
    except ImportError:
        return {}
    matches = list(CLUPA_TMP.rglob("CLUPA_PROVINCIAL.shp"))
    if not matches:
        return {}
    reader = shapefile.Reader(str(matches[0]))
    fields = [f[0] for f in reader.fields[1:]]
    out: dict[str, str] = {}
    try:
        for record in reader.iterRecords():
            attrs = dict(zip(fields, record, strict=False))
            ident = str(attrs.get("POL_IDENT") or "").strip()
            if not ident or ident in out:
                continue
            name = clean(str(attrs.get("NAME_ENG") or ""))
            desig = clean(str(attrs.get("DESIG_ENG") or ""))
            if name and desig and desig.lower() not in name.lower():
                out[ident] = f"{name} ({desig})"
            else:
                out[ident] = name or desig
    finally:
        reader.close()
    return out


def build_permitted_index(path: Path) -> dict[str, list[dict]]:
    header, rows = read_rows(path)
    idx = {name: i for i, name in enumerate(header)}
    out: dict[str, list[dict]] = {}
    for row in rows:
        policy_ogf = row[idx["CLUPA_POLICY_ID"]].strip()
        if not policy_ogf:
            continue
        out.setdefault(policy_ogf, []).append(
            {
                "class": clean(row[idx["PERMITTED_USE_CLASS_ENG"]]),
                "use": clean(row[idx["PERMITTED_USE_TYPE_ENG"]]),
                "permitted": clean(row[idx["PERMITTED_FLG_ENG"]]),
                "guidelines": clean(row[idx["PERMITTED_USE_GUIDELINES_ENG"]]),
            }
        )
    return out


def hunting_verdict(uses: list[dict]) -> tuple[object, list[dict]]:
    """Return (hunting_allowed, matching rows) using official permitted uses."""
    hunting_rows = [u for u in uses if "hunt" in u["use"].lower()]
    if not hunting_rows:
        return None, []
    general = [u for u in hunting_rows if u["use"].strip().lower() == "hunting"]
    basis = general or hunting_rows
    flags = {u["permitted"].strip().lower() for u in basis}
    if flags == {"yes"}:
        verdict: object = True
    elif flags == {"no"}:
        verdict = False
    else:
        verdict = "conditional"
    if verdict is True and len(hunting_rows) > len(general or hunting_rows):
        # Extra qualified rows (e.g. non-resident bear) exist alongside a Yes.
        if any(u["permitted"].strip().lower() == "no" for u in hunting_rows):
            verdict = "conditional"
    return verdict, hunting_rows


def render(policy: dict, uses: list[dict]) -> str:
    ident = policy["ident"]
    lines: list[str] = []
    lines.append(f"# Crown Land Use Policy — {ident}")
    lines.append("")
    if policy["name"]:
        lines.append(f"**Name:** {policy['name']}  ")
    lines.append(f"**Policy ID:** {ident}  ")
    if policy["area_ha"]:
        lines.append(f"**Official area:** {policy['area_ha']} ha  ")
    if policy["updated"]:
        lines.append(f"**Policy last updated:** {policy['updated']}  ")
    lines.append("**Jurisdiction:** Ontario (Crown Land Use Policy Atlas)  ")
    lines.append(f"**Official policy report:** {report_url(ident)}")
    lines.append("")

    verdict, hunting_rows = hunting_verdict(uses)
    label = {
        True: "Listed as a permitted use",
        False: "Listed as **not** permitted",
        "conditional": "Permitted with conditions / varies by category",
        None: "Not addressed in this policy",
    }[verdict if verdict in (True, False, None) else "conditional"]
    lines.append("## Hunting")
    lines.append("")
    lines.append(f"{label}.")
    lines.append("")
    if hunting_rows:
        lines.append("| Use | Permitted | Guidelines |")
        lines.append("|---|---|---|")
        for row in hunting_rows:
            lines.append(
                f"| {md_escape(row['use'])} | {md_escape(row['permitted']) or '—'} "
                f"| {md_escape(row['guidelines']) or '—'} |"
            )
        lines.append("")
    lines.append(
        "Provincial season, licence, tag and firearm rules still apply, as do "
        "municipal discharge by-laws. Verify before hunting."
    )
    lines.append("")

    if policy["land_area"]:
        lines.append("## Land area description")
        lines.append("")
        lines.append(policy["land_area"])
        lines.append("")
    if policy["intent"]:
        lines.append("## Land use intent")
        lines.append("")
        lines.append(policy["intent"])
        lines.append("")
    if policy["preface"]:
        lines.append("## Permitted uses — preface")
        lines.append("")
        lines.append(policy["preface"])
        lines.append("")

    other = [u for u in uses if u not in hunting_rows]
    if other:
        lines.append("## Other permitted uses")
        lines.append("")
        lines.append("| Class | Use | Permitted |")
        lines.append("|---|---|---|")
        for row in sorted(other, key=lambda u: (u["class"], u["use"])):
            lines.append(
                f"| {md_escape(row['class']) or '—'} | {md_escape(row['use']) or '—'} "
                f"| {md_escape(row['permitted']) or '—'} |"
            )
        lines.append("")

    if policy["addendum"]:
        lines.append("## Addendum")
        lines.append("")
        lines.append(policy["addendum"])
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append(
        "Reproduced from the Ontario Crown Land Use Policy Atlas data package "
        f"under the Open Government Licence – Ontario. See {ATLAS_HINT} for the "
        "authoritative current version. Not legal advice."
    )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT_DIR)
    parser.add_argument(
        "--only-referenced",
        action="store_true",
        help="Only emit policies referenced by data/on/overlays/*.geojson",
    )
    args = parser.parse_args()

    policy_csv = find_csv("CLUPA_POLICY.csv")
    uses_csv = find_csv("CLUPA_POLICY_AND_PERMITTED_USE.csv")

    header, rows = read_rows(policy_csv)
    idx = {name: i for i, name in enumerate(header)}
    permitted = build_permitted_index(uses_csv)
    names = policy_names()

    referenced: set[str] | None = None
    if args.only_referenced:
        referenced = set()
        for path in (ROOT / "data/on/overlays").glob("*.geojson"):
            if ".clupa_full." in path.name:
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except Exception:  # noqa: BLE001
                continue
            for feature in data.get("features") or []:
                pid = (feature.get("properties") or {}).get("policy_id")
                if pid:
                    referenced.add(str(pid).strip())
        print(f"Referenced policy ids in overlays: {len(referenced)}")

    args.out.mkdir(parents=True, exist_ok=True)
    for stale in args.out.glob("*.md"):
        if stale.name != "README.md":
            stale.unlink()

    written = 0
    hunting_yes = 0
    index: dict[str, dict] = {}
    for row in rows:
        ident = row[idx["POLICY_IDENT"]].strip()
        if not ident:
            continue
        if referenced is not None and ident not in referenced:
            continue
        ogf = row[idx["OGF_ID"]].strip()
        uses = permitted.get(ogf, [])
        policy = {
            "ident": ident,
            "name": names.get(ident, ""),
            "land_area": clean(row[idx["LAND_AREA_DESCR_ENG"]]),
            "intent": clean(row[idx["LAND_USE_INTENT_DESCR_ENG"]]),
            "preface": clean(row[idx["PERMITTED_USES_PREFACE_ENG"]]),
            "addendum": clean(row[idx["PERMITTED_USES_ADDENDUM_ENG"]]),
            "area_ha": clean(row[idx["OFFICIAL_AREA_HA"]]),
            "updated": fmt_date(row[idx["DATE_POLICY_LAST_UPDATED"]]),
        }
        (args.out / f"{ident}.md").write_text(render(policy, uses), encoding="utf-8")
        written += 1
        verdict, _ = hunting_verdict(uses)
        if verdict is True:
            hunting_yes += 1
        index[ident] = {
            "hunting_allowed": verdict,
            "url": report_url(ident),
            "area_ha": policy["area_ha"],
        }

    index_path = args.out.parent / "policy_index.json"
    index_path.write_text(
        json.dumps(
            {
                "source": "Ontario CLUPA policy package (CLUPAPRO.zip)",
                "license": "OGL-Ontario",
                "policy_count": len(index),
                "policies": index,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print(
        f"Wrote {written} policy files -> {args.out} "
        f"(hunting permitted in {hunting_yes})"
    )
    print(f"Wrote policy index -> {index_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
