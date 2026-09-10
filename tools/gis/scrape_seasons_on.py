#!/usr/bin/env python3
"""Scrape every Ontario open-season table into one WMU-indexed season pack.

Source: the Ontario Hunting Regulations Summary chapters on ontario.ca. Each
species chapter publishes plain HTML tables shaped

    | Wildlife management unit | <residency> - open season | limits/hunt code |

so the whole province can be read without a PDF parser. This runs at pack build
time (there is no seasons API), and the output is committed for review before it
ships, because hunters act on these dates.

Usage:
    python scrape_seasons_on.py [--year 2026] [--out ../../data/on/seasons/2026.json]
"""

from __future__ import annotations

import argparse
import calendar
import html as htmllib
import json
import re
import sys
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WMU_PATH = ROOT / "data/on/overlays/wmu.geojson"

BASE = "https://www.ontario.ca/document/ontario-hunting-regulations-summary"
REGS_URL = BASE
UA = {"User-Agent": "Mozilla/5.0 (compatible; OpenWoodsMap season builder)"}

# Chapter slug -> (display species fallback, group). Chapters where one page is
# one species carry the species name; the small-game page names its species in
# the heading above each table instead.
CHAPTERS: list[tuple[str, str | None, str]] = [
    ("white-tailed-deer", "White-tailed deer", "big_game"),
    ("moose", "Moose", "big_game"),
    ("black-bear", "Black bear", "big_game"),
    ("elk", "Elk", "big_game"),
    ("wild-turkey", "Wild turkey", "wild_turkey"),
    ("wolf-and-coyote", "Wolf and coyote", "furbearer"),
    ("small-game-and-furbearing-mammals", None, "small_game"),
]

# Species on the small-game chapter that are regulated as furbearers. Checked
# only after SMALL_GAME_HINTS, so "gray and fox squirrel" stays small game.
FURBEARER_HINTS = (
    "fox",
    "raccoon",
    "opossum",
    "skunk",
    "weasel",
    "wolf",
    "coyote",
    "marten",
    "fisher",
)
SMALL_GAME_HINTS = (
    "squirrel",
    "grouse",
    "pheasant",
    "partridge",
    "ptarmigan",
    "hare",
    "cottontail",
    "rabbit",
    "bullfrog",
    "cormorant",
    "crow",
)

MONTHS = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}
MONTH_RE = "|".join(MONTHS)

# The regulation year runs spring-to-spring: a season starting in April or later
# belongs to the opening calendar year, January-March dates roll into the next.
YEAR_PIVOT_MONTH = 4


# --------------------------------------------------------------------------- #
# HTML helpers
# --------------------------------------------------------------------------- #


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read().decode("utf-8", errors="replace")


def cell_text(fragment: str) -> str:
    """Flatten a table cell to text, dropping footnote markers and links."""
    fragment = re.sub(r"<sup.*?</sup>", " ", fragment, flags=re.S)
    fragment = re.sub(r"<[^>]+>", " ", fragment)
    text = htmllib.unescape(fragment)
    text = re.sub(r"footnote\s*\d+\s*(\[\d+\])?", " ", text, flags=re.I)
    text = re.sub(r"\[\d+\]", " ", text)
    text = text.replace("\u00a0", " ")
    return " ".join(text.split())


def table_rows(table_html: str) -> list[list[str]]:
    rows = []
    for row in re.findall(r"<tr.*?</tr>", table_html, re.S):
        cells = [
            cell_text(cell) for cell in re.findall(r"<t[hd].*?</t[hd]>", row, re.S)
        ]
        if cells:
            rows.append(cells)
    return rows


def heading_before(page: str, offset: int) -> str:
    """Nearest h2/h3 above a table; it names the species or the weapon class."""
    window = page[max(0, offset - 2500) : offset]
    headings = re.findall(r"<h[234][^>]*>(.*?)</h[234]>", window, re.S)
    return cell_text(headings[-1]) if headings else ""


# --------------------------------------------------------------------------- #
# Dates
# --------------------------------------------------------------------------- #


def last_day(year: int, month: int) -> int:
    return calendar.monthrange(year, month)[1]


def year_for(month: int, base_year: int) -> int:
    return base_year if month >= YEAR_PIVOT_MONTH else base_year + 1


def parse_endpoint(token: str, base_year: int) -> tuple[int, int, int] | None:
    """Parse 'October 9' or 'the last day of February' into (y, m, d)."""
    token = token.strip().rstrip(".,;")
    match = re.match(rf"(?i)^(?:the\s+)?last\s+day\s+of\s+({MONTH_RE})$", token)
    if match:
        month = MONTHS[match.group(1).lower()]
        year = year_for(month, base_year)
        return year, month, last_day(year, month)
    match = re.match(rf"(?i)^({MONTH_RE})\s+(\d{{1,2}})$", token)
    if match:
        month = MONTHS[match.group(1).lower()]
        day = int(match.group(2))
        return year_for(month, base_year), month, day
    return None


def parse_date_cell(text: str, base_year: int) -> list[dict]:
    """Parse one open-season cell into concrete ISO ranges.

    Handles 'September 15 to March 31', 'All year', 'None', the glued multi-range
    form 'October 1 to November 1November 16 to November 30', and endpoints
    written as 'the last day of February'.
    """
    raw = (text or "").strip()
    if not raw or raw.lower() in {"none", "n/a", "no season", "closed", "-", "—"}:
        return []

    if re.search(r"(?i)\ball\s+year\b", raw):
        return [
            {
                "start": f"{base_year}-{YEAR_PIVOT_MONTH:02d}-01",
                "end": f"{base_year + 1}-{YEAR_PIVOT_MONTH - 1:02d}-"
                f"{last_day(base_year + 1, YEAR_PIVOT_MONTH - 1):02d}",
                "all_year": True,
            }
        ]

    # Split date endpoints that ran together across two ranges ("...15November...").
    cleaned = re.sub(rf"(?i)(\d)({MONTH_RE})", r"\1 \2", raw)
    cleaned = re.sub(rf"(?i)(day of ({MONTH_RE}))({MONTH_RE})", r"\1 \3", cleaned)

    endpoints = re.findall(
        rf"(?i)(?:the\s+)?last\s+day\s+of\s+(?:{MONTH_RE})|(?:{MONTH_RE})\s+\d{{1,2}}",
        cleaned,
    )
    ranges = []
    for index in range(0, len(endpoints) - 1, 2):
        start = parse_endpoint(endpoints[index], base_year)
        end = parse_endpoint(endpoints[index + 1], base_year)
        if not start or not end:
            continue
        if (end[1], end[2]) < (start[1], start[2]) and end[0] == start[0]:
            end = (end[0] + 1, end[1], end[2])
        ranges.append(
            {
                "start": f"{start[0]:04d}-{start[1]:02d}-{start[2]:02d}",
                "end": f"{end[0]:04d}-{end[1]:02d}-{end[2]:02d}",
            }
        )
    return ranges


# --------------------------------------------------------------------------- #
# WMU expansion
# --------------------------------------------------------------------------- #


def load_wmu_ids() -> list[str]:
    data = json.loads(WMU_PATH.read_text(encoding="utf-8"))
    ids = set()
    for feature in data.get("features", []):
        props = feature.get("properties") or {}
        wmu = str(props.get("wmu_id") or props.get("name") or "").strip()
        if wmu:
            ids.add(wmu)
    return sorted(ids, key=wmu_sort_key)


def wmu_sort_key(wmu: str):
    match = re.match(r"^(\d+)([A-Za-z0-9]*)$", wmu)
    if not match:
        return (9999, wmu)
    return (int(match.group(1)), match.group(2))


def numeric_base(wmu: str) -> int | None:
    match = re.match(r"^(\d+)", wmu)
    return int(match.group(1)) if match else None


def normalize(wmu: str) -> str:
    """Drop separators so the map's '69A-1' matches the regulation's '69A1'."""
    return re.sub(r"[^A-Z0-9]", "", wmu.upper())


def expand_token(token: str, known: list[str]) -> list[str]:
    """Expand '5', '69A1' or '12-15' against the real WMU list.

    A bare number or numeric range covers every lettered subunit sharing that
    number, which is how the regulation tables use them (12-15 includes 12A/12B).
    """
    token = token.strip().replace(" ", "")
    if not token:
        return []
    key = normalize(token)
    exact = [wmu for wmu in known if normalize(wmu) == key]
    if exact:
        return exact

    match = re.match(r"^(\d+)[A-Za-z0-9]*[–—-](\d+)[A-Za-z0-9]*$", token)
    if match:
        low, high = int(match.group(1)), int(match.group(2))
        if low > high:
            return []
        return [
            wmu
            for wmu in known
            if (base := numeric_base(wmu)) is not None and low <= base <= high
        ]

    if re.match(r"^\d+$", token):
        return [
            wmu
            for wmu in known
            if normalize(wmu) == key
            or (normalize(wmu).startswith(key) and not normalize(wmu)[len(key)].isdigit())
        ]

    # A parent unit such as "69A" stands in for the mapped 69A-1/69A-2/69A-3.
    if re.match(r"^\d+[A-Za-z]$", token):
        return [wmu for wmu in known if normalize(wmu).startswith(key)]
    return []


def expand_wmu_cell(cell: str, known: list[str]) -> tuple[list[str], list[str]]:
    out: list[str] = []
    seen: set[str] = set()
    unmatched: list[str] = []
    for part in re.split(r"[,;]", cell):
        part = part.strip()
        if not part:
            continue
        hits = expand_token(part, known)
        if not hits:
            unmatched.append(part)
        for wmu in hits:
            if wmu not in seen:
                seen.add(wmu)
                out.append(wmu)
    return sorted(out, key=wmu_sort_key), unmatched


# --------------------------------------------------------------------------- #
# Table interpretation
# --------------------------------------------------------------------------- #


def residency_of(header: str) -> str | None:
    low = header.lower()
    if "open season" not in low:
        return None
    has_non_resident = bool(re.search(r"non[\s-]*resident", low))
    has_resident = bool(re.search(r"(?<!non[\s-])\bresident\b", low))
    if has_non_resident and has_resident:
        return "any"
    if has_non_resident:
        return "non_resident"
    return "resident"


def column_index(headers: list[str], *patterns: str) -> int | None:
    for index, header in enumerate(headers):
        low = header.lower()
        if any(re.search(pattern, low) for pattern in patterns):
            return index
    return None


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return slug or "unknown"


def clean_heading(heading: str) -> tuple[str, str | None]:
    """Strip the word 'season(s)' and split off any trailing parenthetical note.

    'Ruffed grouse seasons (no season for spruce grouse in these units)'
    becomes ('Ruffed grouse', 'no season for spruce grouse in these units').
    """
    note = None
    match = re.search(r"\(([^)]+)\)\s*$", heading)
    if match:
        note = match.group(1).strip()
        heading = heading[: match.start()]
    text = re.sub(r"(?i)\bseasons?\b(\s+and\s+limits)?", " ", heading)
    return " ".join(text.split()).strip(" -–—"), note


def species_from(
    heading: str, chapter_species: str | None
) -> tuple[str, str, str | None]:
    """Return (species display name, season label, heading note) for a table."""
    label, note = clean_heading(heading)
    if chapter_species:
        # "Spring black bear seasons" -> species from the chapter, label "Spring".
        trimmed = re.sub(rf"(?i)\b{re.escape(chapter_species)}\b", " ", label)
        trimmed = " ".join(trimmed.split()).strip(" -–—")
        return chapter_species, trimmed, note
    # Small-game chapter: the heading names the species, then any weapon note.
    parts = re.split(r"\s+[-–—]\s+", label, maxsplit=1)
    return parts[0].strip(), (parts[1].strip() if len(parts) > 1 else ""), note


def group_for(species_name: str, default_group: str) -> str:
    low = species_name.lower()
    if default_group != "small_game":
        return default_group
    if any(hint in low for hint in SMALL_GAME_HINTS):
        return "small_game"
    return "furbearer" if any(hint in low for hint in FURBEARER_HINTS) else "small_game"


def parse_chapter(
    slug: str,
    chapter_species: str | None,
    group: str,
    known: list[str],
    base_year: int,
    warnings: list[str],
) -> list[dict]:
    page = fetch(f"{BASE}/{slug}")
    entries: list[dict] = []

    for table_html in re.findall(r"<table.*?</table>", page, re.S):
        rows = table_rows(table_html)
        if len(rows) < 2:
            continue
        headers = rows[0]
        season_columns = {
            index: residency
            for index, header in enumerate(headers)
            if (residency := residency_of(header))
        }
        if not season_columns:
            continue
        wmu_column = column_index(headers, r"wildlife management unit", r"^wmu$")
        if wmu_column is None:
            warnings.append(f"{slug}: season table without a WMU column: {headers}")
            continue

        limits_column = column_index(headers, r"limit")
        hunt_code_column = column_index(headers, r"hunt code")
        firearm_column = column_index(headers, r"firearm")
        notes_column = column_index(headers, r"restriction", r"tag requirement")

        heading = heading_before(page, page.find(table_html))
        species_name, season_label, heading_note = species_from(
            heading, chapter_species
        )
        species_group = group_for(species_name, group)

        for row in rows[1:]:
            if len(row) <= wmu_column:
                continue
            wmus, unmatched = expand_wmu_cell(row[wmu_column], known)
            if unmatched:
                warnings.append(
                    f"{slug} [{species_name}]: unmatched WMU token(s) "
                    f"{unmatched} in {row[wmu_column]!r}"
                )
            if not wmus:
                continue

            def value(index: int | None) -> str | None:
                if index is None or index >= len(row):
                    return None
                text = row[index].strip()
                return text or None

            notes = " ".join(
                part for part in (heading_note, value(notes_column)) if part
            )
            base = {
                "species": slugify(species_name),
                "species_name": species_name,
                "group": species_group,
                # Weapon class ("Bows only") or season name ("Spring").
                "label": value(firearm_column) or season_label or None,
                "limits": value(limits_column),
                "hunt_code": value(hunt_code_column),
                "notes": notes or None,
                "wmus": wmus,
            }
            for index, residency in season_columns.items():
                if index >= len(row):
                    continue
                for span in parse_date_cell(row[index], base_year):
                    entries.append(
                        {
                            **base,
                            "residency": residency,
                            "start": span["start"],
                            "end": span["end"],
                            **({"all_year": True} if span.get("all_year") else {}),
                            "source_text": row[index].strip(),
                        }
                    )
    return entries


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #


def build_payload(entries: list[dict], base_year: int, known: list[str]) -> dict:
    """Emit one shared season list plus per-WMU indexes into it.

    Most rows apply to dozens of WMUs, so storing the row once and referencing
    it by index keeps the pack an order of magnitude smaller than inlining.
    """
    species_labels: dict[str, str] = {}
    groups: dict[str, str] = {}
    seasons: list[dict] = []
    season_index: dict[str, int] = {}
    units: dict[str, list[int]] = {}

    for entry in entries:
        species_labels[entry["species"]] = entry["species_name"]
        groups[entry["species"]] = entry["group"]
        season = {
            key: entry[key]
            for key in (
                "species",
                "label",
                "residency",
                "start",
                "end",
                "limits",
                "hunt_code",
                "notes",
            )
            if entry.get(key)
        }
        if entry.get("all_year"):
            season["all_year"] = True
        key = json.dumps(season, sort_keys=True)
        index = season_index.get(key)
        if index is None:
            index = len(seasons)
            season_index[key] = index
            seasons.append(season)
        for wmu in entry["wmus"]:
            bucket = units.setdefault(wmu, [])
            if index not in bucket:
                bucket.append(index)

    for indexes in units.values():
        indexes.sort(key=lambda i: (seasons[i]["start"], seasons[i]["species"]))

    return {
        "seasons": seasons,
        "province": "on",
        "year": base_year,
        "schema": 2,
        "zone_kind": "wmu",
        "season_year_label": f"{base_year}–{str(base_year + 1)[-2:]}",
        "season_year_start": f"{base_year}-{YEAR_PIVOT_MONTH:02d}-01",
        "season_year_end": f"{base_year + 1}-{YEAR_PIVOT_MONTH - 1:02d}-"
        f"{last_day(base_year + 1, YEAR_PIVOT_MONTH - 1):02d}",
        "generated": date.today().isoformat(),
        "source": {
            "title": "Ontario Hunting Regulations Summary",
            "url": REGS_URL,
            "regs_summary_url": REGS_URL,
            "license": "Crown copyright — King's Printer for Ontario",
            "coverage": (
                "Open seasons for every species with a published WMU season "
                "table: deer, moose, black bear, elk, wild turkey, wolf/coyote, "
                "upland birds, hares, squirrels, bullfrog and furbearers. "
                "Migratory birds are federally regulated and are not included."
            ),
        },
        "disclaimer": (
            "Informational only. Seasons, weapons, tags, draws and controlled "
            "hunts change every year and differ by WMU. Confirm against the "
            "current Ontario Hunting Regulations Summary before you hunt."
        ),
        "species_labels": dict(sorted(species_labels.items(), key=lambda kv: kv[1])),
        "species_groups": groups,
        "group_labels": {
            "big_game": "Big game",
            "wild_turkey": "Wild turkey",
            "small_game": "Small game",
            "furbearer": "Furbearers",
        },
        "units": {
            wmu: units[wmu] for wmu in sorted(units, key=wmu_sort_key)
        },
        "units_without_seasons": [wmu for wmu in known if wmu not in units],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--year", type=int, default=2026, help="Regulation year")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    out = args.out or ROOT / f"data/on/seasons/{args.year}.json"
    known = load_wmu_ids()
    print(f"{len(known)} WMUs in {WMU_PATH.name}")

    warnings: list[str] = []
    entries: list[dict] = []
    for slug, species, group in CHAPTERS:
        found = parse_chapter(slug, species, group, known, args.year, warnings)
        entries.extend(found)
        print(f"  {slug}: {len(found)} season rows")

    if not entries:
        print("No seasons parsed - the page layout probably changed.", file=sys.stderr)
        return 1

    payload = build_payload(entries, args.year, known)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    species_count = len(payload["species_labels"])
    covered = len(payload["units"])
    print(
        f"\nWrote {covered}/{len(known)} WMUs, {species_count} species, "
        f"{len(entries)} rows -> {out} ({out.stat().st_size / 1e3:.0f} KB)"
    )
    if payload["units_without_seasons"]:
        print(f"WMUs with no season rows: {payload['units_without_seasons']}")
    for warning in dict.fromkeys(warnings):
        print(f"WARN {warning}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
