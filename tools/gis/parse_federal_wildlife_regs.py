#!/usr/bin/env python3
"""Parse the two federal regulations that close land to hunting, into rules.

National Wildlife Areas and Migratory Bird Sanctuaries are drawn by ECCC but
their prohibitions live in regulations, and both are stricter than "no
hunting" in ways a hunter would not guess:

  Wildlife Area Regulations, C.R.C. c. 1609
      s. 3(1)(b) and (c) prohibit hunting *and* possessing equipment that could
      be used for hunting in any wildlife area. s. 3.1 then lets the activities
      listed in Schedule I.1 be carried out without a permit, so Schedule I.1
      is the only thing that can open an NWA. In Ontario it opens sport hunting
      of waterfowl in exactly two of them. s. 3.3(1) additionally bars entry to
      three Ontario NWAs without a permit.

  Migratory Bird Sanctuary Regulations, C.R.C. c. 1036
      s. 3(2)(a) prohibits hunting migratory birds, which alone would leave deer
      hunting untouched. s. 4(1) then prohibits possessing *any* firearm or any
      hunting appliance in a sanctuary, which closes it to hunting anything by
      any means. That second prohibition is the one that catches a hunter
      walking through with a slung rifle.

Both are read from the Justice Laws XML consolidation rather than restated here,
so the app quotes the regulation instead of quoting us, and a name in ECCC's
geometry that is not in the current schedule can be reported as unverified
rather than silently assumed closed.

Writes data/on/rules/federal_wildlife.json (committed: small, and needed to
build the overlay).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/rules/federal_wildlife.json"

XML = "https://laws-lois.justice.gc.ca/eng/XML/{}.xml"
PAGE = "https://laws-lois.justice.gc.ca/eng/regulations/{}/"

WAR = "C.R.C.,_c._1609"
MBSR = "C.R.C.,_c._1036"

# Schedule I lists the wildlife areas; Schedule I.1 lists what may be done in
# them. Only the second can open one to hunting.
NWA_AREAS_SCHEDULE = "SCHEDULE I"
NWA_ACTIVITIES_SCHEDULE = "SCHEDULE I.1"


def fetch(citation: str, attempts: int = 4) -> str:
    request = urllib.request.Request(
        XML.format(citation), headers={"User-Agent": "OpenWoodsMap/1.0"}
    )
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return response.read().decode("utf-8", errors="replace")
        except Exception as error:  # noqa: BLE001
            if attempt == attempts - 1:
                raise
            print(f"  {type(error).__name__}, retrying …", flush=True)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("unreachable")


def plain(fragment: str) -> str:
    out = re.sub(r"<[^>]+>", " ", fragment)
    out = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), out)
    for entity, char in (("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                         ("&quot;", '"'), ("&apos;", "'")):
        out = out.replace(entity, char)
    return re.sub(r"\s+", " ", out).strip()


def currency(xml: str) -> str:
    """Latest amendment date the consolidation carries."""
    dates = re.findall(r'lims:lastAmendedDate="(\d{4}-\d{2}-\d{2})"', xml)
    return max(dates) if dates else ""


def section(xml: str, label: str) -> str:
    for block in re.findall(r"<Section\b[^>]*>.*?</Section>", xml, re.S):
        found = re.search(r"<Label>(.*?)</Label>", block, re.S)
        if found and plain(found.group(1)) == label:
            return plain(block)
    return ""


def schedule(xml: str, label: str) -> str:
    """Return the XML of one schedule, matched on its own label.

    Schedules nest, so the closing tag has to be found by depth rather than by
    the next `</Schedule>`, or Schedule I swallows Schedule I.1.
    """
    for match in re.finditer(r"<Schedule\b[^>]*>", xml):
        depth, position = 1, match.end()
        while depth:
            nxt = re.search(r"<(/?)Schedule\b[^>]*>", xml[position:])
            if not nxt:
                break
            depth += -1 if nxt.group(1) else 1
            position += nxt.end()
        body = xml[match.end():position]
        head = re.search(r"<Label>(.*?)</Label>", body, re.S)
        if head and plain(head.group(1)).upper() == label.upper():
            return body
    return ""


def headings(body: str) -> list[tuple[str, str, int, int]]:
    """Every heading as (label, title, start of content, end of heading tag)."""
    out = []
    for match in re.finditer(r"<Heading\b[^>]*>(.*?)</Heading>", body, re.S):
        inner = match.group(1)
        label = re.search(r"<Label>(.*?)</Label>", inner, re.S)
        title = re.search(r"<TitleText>(.*?)</TitleText>", inner, re.S)
        out.append(
            (
                plain(label.group(1)) if label else "",
                plain(title.group(1)) if title else "",
                match.end(),
                match.start(),
            )
        )
    return out


def province_region(body: str, part: str, province: str) -> str:
    """Slice one province's part out of a schedule.

    Matched on the heading's own label and title rather than on their distance
    apart in the markup: "Ontario and Nunavut" carries an amendment note that
    puts the closing tag far past the province name.
    """
    marks = headings(body)
    for index, (label, title, content, _) in enumerate(marks):
        if label.upper() != f"PART {part}".upper() or province not in title:
            continue
        for later_label, _, _, start in marks[index + 1:]:
            if later_label.upper().startswith("PART "):
                return body[content:start]
        return body[content:]
    return ""


def provisions(region: str) -> list[tuple[str, str]]:
    """Top-level (label, text) pairs of a schedule part.

    Items are `<Provision><Label>1</Label><Text>Name</Text>` with the
    description in nested provisions, so reading the first Text after each label
    gives the name alone. Labels are not always integers: Long Point was
    inserted as item 3.1. Names are sometimes wrapped in `<Emphasis>`, so the
    text has to be stripped rather than matched as a bare character run.
    """
    return [
        (label, plain(text))
        for label, text in re.findall(
            r"<Label>([\d.]+)</Label>\s*<Text>(.*?)</Text>", region, re.S
        )
    ]


def area_names(region: str, suffix: str) -> list[str]:
    """Names of the areas a schedule part lists, in schedule order.

    A part holding a single area does not number it, so the labelled pass finds
    nothing and every text has to be considered. Hannah Bay is the only Ontario
    case, having been moved into a shared Ontario and Nunavut part by
    SOR/2025-99.
    """
    seen: list[str] = []
    labelled = [text for _, text in provisions(region)]
    for text in labelled or [
        plain(match) for match in re.findall(r"<Text>(.*?)</Text>", region, re.S)
    ]:
        if text.endswith(suffix) and text not in seen:
            seen.append(text)
    return seen


def activity_blocks(region: str) -> dict[str, list[str]]:
    """{area name: [authorised activities]} from Schedule I.1."""
    out: dict[str, list[str]] = {}
    marks = headings(region)
    for index, (_, title, content, _) in enumerate(marks):
        stop = marks[index + 1][3] if index + 1 < len(marks) else len(region)
        out[title] = [text for _, text in provisions(region[content:stop]) if text]
    return out


def no_entry_areas(war: str, province_part: str) -> list[tuple[str, str]]:
    """Areas s. 3.3(1) bars entry to, as (name, paragraph) for one province."""
    text = section(war, "3.3")
    found: list[tuple[str, str]] = []
    for paragraph in re.finditer(
        r"\(([a-z](?:\.\d+)?)\)\s*(.+?National Wildlife Area).*?"
        r"item\s+\d+\s+of\s+Part\s+([IVXL]+)\s+of\s+Schedule\s+I",
        text,
        re.S,
    ):
        if paragraph.group(3).upper() == province_part.upper():
            found.append((paragraph.group(2).strip(), paragraph.group(1)))
    return found


def normalize(value: str) -> str:
    """Fold a protected-area name so ECCC's geometry and the schedule meet.

    ECCC writes "Migratory Bird Sanctuary" where the regulation writes "Bird
    Sanctuary", and splits several areas into named units the regulation does
    not distinguish. Unit suffixes are stripped by the caller, not here.
    """
    text = (value or "").upper().replace("’", "'")
    text = text.replace("MIGRATORY BIRD SANCTUARY", "BIRD SANCTUARY")
    text = re.sub(r"\bST\.?\s", "ST ", text)
    text = re.sub(r"[^A-Z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def hunting_activities(activities: list[str]) -> list[str]:
    return [item for item in activities if re.search(r"\bhunting\b", item, re.I)
            and not re.search(r"^Operation by sport hunters|^Overnight parking",
                              item, re.I)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    # Ontario is Part IV of the wildlife-area schedules and Part VI of the
    # sanctuary schedule. Hannah Bay moved to a shared "Ontario and Nunavut"
    # part in SOR/2025-99, so the sanctuary side reads both.
    parser.add_argument("--nwa-part", default="IV")
    parser.add_argument("--mbs-parts", default="VI,XII")
    parser.add_argument("--province", default="Ontario")
    args = parser.parse_args()

    print("Fetching Wildlife Area Regulations …", flush=True)
    war = fetch(WAR)
    print("Fetching Migratory Bird Sanctuary Regulations …", flush=True)
    mbsr = fetch(MBSR)

    areas_region = province_region(
        schedule(war, NWA_AREAS_SCHEDULE), args.nwa_part, args.province
    )
    listed = area_names(areas_region, "National Wildlife Area")
    activities_region = province_region(
        schedule(war, NWA_ACTIVITIES_SCHEDULE), args.nwa_part, args.province
    )
    opened = activity_blocks(activities_region)
    barred = dict(no_entry_areas(war, args.nwa_part))
    if not listed or not opened:
        print("Parsed no NWAs; Justice Laws markup may have changed",
              file=sys.stderr)
        return 1

    nwa: list[dict] = []
    for name in listed:
        activities = opened.get(name, [])
        hunting = hunting_activities(activities)
        nwa.append(
            {
                "name": name,
                "hunting_authorized": bool(hunting),
                "hunting_activities": hunting,
                "activities_listed": bool(activities),
                "no_entry": name in barred,
                "no_entry_paragraph": (
                    f"s. 3.3(1)({barred[name]})" if name in barred else None
                ),
            }
        )

    mbs: list[dict] = []
    for part in args.mbs_parts.split(","):
        region = province_region(schedule(mbsr, "SCHEDULE"), part.strip(),
                                 args.province)
        for name in area_names(region, "Bird Sanctuary"):
            mbs.append({"name": name, "part": part.strip()})

    if not mbs:
        print("Parsed no sanctuaries", file=sys.stderr)
        return 1

    payload = {
        "province": "on",
        "nwa": {
            "citation": "Wildlife Area Regulations, C.R.C., c. 1609, under the "
                        "Canada Wildlife Act",
            "source": PAGE.format(WAR),
            "currency_date": currency(war),
            "prohibition": section(war, "3")[:1200],
            "opening_rule": section(war, "3.1"),
            "areas": nwa,
        },
        "mbs": {
            "citation": "Migratory Bird Sanctuary Regulations, C.R.C., c. 1036, "
                        "under the Migratory Birds Convention Act, 1994",
            "source": PAGE.format(MBSR),
            "currency_date": currency(mbsr),
            "hunting_prohibition": section(mbsr, "3"),
            "firearm_prohibition": section(mbsr, "4"),
            "areas": mbs,
        },
        "license": "Reproduced from the Justice Laws Website consolidation. "
                   "Not the official version.",
        "license_url": "https://laws-lois.justice.gc.ca/eng/reproduction/",
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                        encoding="utf-8")

    open_nwa = [a["name"] for a in nwa if a["hunting_authorized"]]
    print(f"\nNWA: {len(nwa)} listed in {args.province}, "
          f"{len(open_nwa)} authorize hunting: {', '.join(open_nwa) or 'none'}")
    print(f"     {sum(1 for a in nwa if a['no_entry'])} barred to entry "
          f"without a permit")
    print(f"MBS: {len(mbs)} sanctuaries")
    print(f"Wrote {args.out} ({args.out.stat().st_size / 1000:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
