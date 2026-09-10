#!/usr/bin/env python3
"""Parse O. Reg. 663/98 (Area Descriptions) into machine-readable hunting rules.

Two parts of this regulation decide legality in ways no Ontario GIS layer
carries, so they have to come from the legal text:

Part 3  The Crown lands and provincial park lands where hunting *is* permitted.
        Hunting in a provincial park is otherwise prohibited, so a park absent
        from these schedules is closed. Most schedules open only a described
        piece of a park, and those pieces are metes-and-bounds prose referring
        to plans deposited with the Surveyor General. They are not mappable, so
        the description is carried verbatim and the park is reported as
        partially open rather than open.

Part 7  The municipalities south of the French and Mattawa rivers where Sunday
        gun hunting is permitted. North of those rivers it is permitted
        generally, so an unlisted southern municipality is a prohibition.

Source is the e-Laws v2 API, which serves the consolidated current version and
its currency date; the public HTML page is a JavaScript shell with no content.

Writes data/on/rules/reg663.json (committed: small, and the pack needs it).
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data/on/rules/reg663.json"
API = (
    "https://www.ontario.ca/laws/api/v2/legislation/en/doc-search/"
    "regulation/980663"
)
CITATION = "O. Reg. 663/98 (Area Descriptions) under the Fish and Wildlife Conservation Act, 1997"
SOURCE_PAGE = "https://www.ontario.ca/laws/regulation/980663"

# A schedule that only names places opens the whole area; one that surveys a
# boundary opens a piece of it. Survey prose and a "part of" opening are what
# separate the two. An "excepting" clause is deliberately not a partial marker:
# Grundy Lake opens the whole park except where signs are posted, and
# Chapleau-Nemegosenda opens the whole park except the Crown game preserve we
# already map as its own layer. Those are whole openings carrying a carve-out.
SURVEY_MARKERS = (
    "beginning at",
    "thence",
    "more or less",
    "designated as part",
    "described as follows",
    "on a plan",
    "hectares",
    "degrees",
)
PARTIAL_MARKERS = ("part of", "portion of", "parts of", "portions of")
# An excepting clause is about what is carved out, not about how much is opened,
# and it is the one place "part of" appears in an otherwise whole opening. It is
# removed before the partial test so that Grundy Lake stays a whole opening while
# Algonquin, which opens only the McRae Addition, does not.
EXCEPT_CLAUSE = re.compile(
    r",?\s*(?:save\s+and\s+)?except(?:ing)?\b.*$", re.I | re.S
)
# Revoked schedules carry their own CSS class, so they are not split points and
# their text runs on into the preceding schedule unless it is trimmed.
REVOKED_TAIL = re.compile(r"\bschedules?\s+\d+\s*,?\s*revoked\s*:.*$", re.I)


def fetch_regulation() -> dict:
    request = urllib.request.Request(
        API, headers={"User-Agent": "OpenWoodsMap/1.0", "Accept": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def strip_tags(fragment: str) -> str:
    text = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def split_parts(content: str) -> dict[str, str]:
    """Return {part number: html} using the regulation's own part headings.

    Revoked and repealed parts keep their heading but use a different class.
    They still have to end the preceding part, or their "Revoked:" line runs on
    into the last schedule of the part before them.
    """
    heads = list(
        re.finditer(
            r'<p class="(partnum-e|partnumRevoked-e|partnumRepeal-e)">(.*?)</p>',
            content,
            re.S | re.I,
        )
    )
    parts: dict[str, str] = {}
    for index, head in enumerate(heads):
        match = re.match(r"Part\s+(\d+)", strip_tags(head.group(2)), re.I)
        if not match or head.group(1) != "partnum-e":
            continue
        end = heads[index + 1].start() if index + 1 < len(heads) else len(content)
        parts[match.group(1)] = content[head.end():end]
    return parts


def parse_part3(fragment: str) -> list[dict]:
    """Schedules of Crown land and park land where hunting is permitted."""
    heads = list(
        re.finditer(
            r'<p class="headingx-e">\s*SCHEDULE\s+(\d+)\s*</p>',
            fragment,
            re.S | re.I,
        )
    )
    schedules: list[dict] = []
    for index, head in enumerate(heads):
        end = heads[index + 1].start() if index + 1 < len(heads) else len(fragment)
        body = fragment[head.end():end]

        citations = [strip_tags(m) for m in re.findall(
            r'<span class="citation">(.*?)</span>', body, re.S
        )]
        # Drop citation spans so they do not pollute the description text.
        text = strip_tags(re.sub(r'<p class="footnote-e">.*?</p>', " ", body, flags=re.S))
        text = re.sub(r"\s*O\.\s*Reg\.[^.]*\.\s*$", "", text).strip()
        text = REVOKED_TAIL.sub("", text).strip()
        if not text:
            continue

        low = text.lower()
        core = EXCEPT_CLAUSE.sub("", low)
        surveyed = any(marker in core for marker in SURVEY_MARKERS) or any(
            marker in core for marker in PARTIAL_MARKERS
        )
        # "excepting those parts posted with signs" and similar carve-outs must
        # reach the user verbatim; flag the schedules that carry one.
        conditional = bool(
            re.search(r"\bexcept|\bexcepting|\bsave and except|posted with signs", low)
        )
        schedules.append(
            {
                "schedule": int(head.group(1)),
                "extent": "part" if surveyed else "whole",
                "conditional": conditional,
                "description": text,
                "citations": citations,
            }
        )
    return schedules


def parse_part7(fragment: str) -> list[dict]:
    """Schedule 1: municipalities permitting Sunday gun hunting."""
    table = re.search(r"<table.*?</table>", fragment, re.S)
    if not table:
        return []
    entries: list[dict] = []
    for row in re.findall(r"<tr.*?</tr>", table.group(0), re.S):
        cells = [strip_tags(c) for c in re.findall(r"<td.*?</td>", row, re.S)]
        if len(cells) < 2:
            continue
        name, area = cells[0], cells[1]
        if not name or name.lower() == "municipality":
            continue
        entries.append({"municipality": name, "geographic_area": area})
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    print("Fetching O. Reg. 663/98 from e-Laws …", flush=True)
    document = fetch_regulation()
    content = document.get("content") or ""
    if not content:
        print("e-Laws returned no content", file=sys.stderr)
        return 1

    currency = strip_tags(str(document.get("dateFrom") or ""))[:10]
    parts = split_parts(content)
    if "3" not in parts or "7" not in parts:
        print(f"Expected Parts 3 and 7, found {sorted(parts)}", file=sys.stderr)
        return 1

    schedules = parse_part3(parts["3"])
    sunday = parse_part7(parts["7"])
    if not schedules or not sunday:
        print("Parsed nothing; regulation markup may have changed", file=sys.stderr)
        return 1

    whole = [s for s in schedules if s["extent"] == "whole"]
    print(f"Part 3: {len(schedules)} schedules, {len(whole)} open in whole, "
          f"{len(schedules) - len(whole)} open a surveyed part, "
          f"{sum(1 for s in schedules if s['conditional'])} carry a carve-out")
    print(f"Part 7: {len(sunday)} municipalities permit Sunday gun hunting")

    payload = {
        "regulation": "O. Reg. 663/98",
        "title": "Area Descriptions",
        "citation": CITATION,
        "source": SOURCE_PAGE,
        "api_source": API,
        "license": "OGL-Ontario",
        "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
        "currency_date": currency,
        "part3": {
            "section": (
                "The designated Crown lands and lands in provincial parks set out "
                "in the Schedules are those lands on which hunting is permitted in "
                "accordance with Part XIV of Ontario Regulation 665/98 (Hunting)."
            ),
            "schedules": schedules,
        },
        "part7": {
            "section": (
                "The municipalities referred to in Schedule 1 are the areas south "
                "of the French and Mattawa rivers where it is permitted to hunt "
                "with a gun on Sundays under Ontario Regulation 665/98 (Hunting) "
                "made under the Act."
            ),
            "municipalities": sunday,
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Wrote {args.out} (currency {currency}, "
          f"{args.out.stat().st_size / 1000:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
