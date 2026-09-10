#!/usr/bin/env python3
"""Parse the hunting provisions of the Provincial Parks and Conservation
Reserves Act, 2006 into machine-readable rules.

Four subsections decide who may hunt on the two kinds of land Ontario Parks
administers. No Ontario GIS layer carries any of them:

s. 15 (1)  Hunting is not permitted in a provincial park unless a regulation
           under the Fish and Wildlife Conservation Act, 1997 allows it. That
           regulation is O. Reg. 663/98 Part 3, which parse_reg663_on.py reads,
           so this is the authority the parks layer already rests on.

s. 15 (2)  Hunting is permitted on the public lands in the Geographic Townships
           of Bruton and Clyde, by the statute itself. This is the one park
           opening the regulation does not carry, so a card built only from
           O. Reg. 663/98 tells a hunter standing in Bruton that Algonquin is
           closed to them when the Act says otherwise.

s. 15 (3)  Hunting is permitted in a conservation reserve unless a regulation
           under the same Act prohibits it — the mirror image of 15 (1). A
           conservation reserve is therefore a permission and not a closure,
           which is why fetch_conservation_reserve_on.py can state one.

s. 12 (3)  Hunting in a conservation reserve may not be constrained by zoning.
           This is what stops a management plan being a hidden exception to
           15 (3), and it is why the reserve layer can say permitted without
           hedging on management direction it does not carry.

Source is the e-Laws v2 API, which serves the consolidated current version and
its consolidation date; the public HTML page is a JavaScript shell.

Writes data/on/rules/ppcra.json (committed: small, and two fetchers read it).
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
OUT = ROOT / "data/on/rules/ppcra.json"
API = (
    "https://www.ontario.ca/laws/api/v2/legislation/en/doc-search/statute/06p12"
)
CITATION = "Provincial Parks and Conservation Reserves Act, 2006, S.O. 2006, c. 12"
SOURCE_PAGE = "https://www.ontario.ca/laws/statute/06p12"

# What each provision is called downstream, and the words that carry its rule.
# The phrase is checked after parsing, so an amendment that changes the meaning
# fails loudly instead of handing the app a rule it would state as law.
WANTED = {
    ("15", "1"): ("parks", "not permitted in provincial parks"),
    ("15", "2"): (
        "algonquin_bruton_clyde",
        "Geographic Townships of Bruton and Clyde",
    ),
    ("15", "3"): ("conservation_reserves", "permitted in conservation reserves"),
    ("12", "3"): (
        "conservation_reserve_zoning",
        "shall not be constrained by zoning",
    ),
}

# Each subsection ends in one or more citation spans naming it. Those are
# provenance, not rule text, and inside a quote the card shows verbatim they
# would read as part of the sentence. e-Laws closes the paragraph *inside* the
# last span, so the paragraph end has to be put back where it belongs first;
# strip the spans as they stand and a subsection runs on into the next headnote.
MISNESTED_CLOSE = re.compile(r"</p>\s*</span>", re.I)
CITATION_SPAN = re.compile(r'<span class="citation">.*?</span>', re.S)


def fetch_statute() -> dict:
    request = urllib.request.Request(
        API, headers={"User-Agent": "OpenWoodsMap/1.0", "Accept": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def strip_tags(fragment: str) -> str:
    text = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(text)
    # e-Laws separates a rule from its citation with a non-breaking space, and
    # uses them inside citations too, so they go before whitespace is collapsed.
    text = text.replace("\xa0", " ")
    text = re.sub(r"\s+", " ", text)
    # Italicised Act names strip to a bare space, which otherwise leaves the
    # quote reading "Fish and Wildlife Conservation Act, 1997 ." on screen.
    text = re.sub(r"\s+([.,;:])", r"\1", text)
    return text.strip()


def subsections(content: str, section: str) -> dict[str, str]:
    """Return {subsection number: text} for one section.

    Keyed off the paragraph classes e-Laws uses rather than off the headnotes,
    which are editorial. The section paragraph carries subsection (1); each later
    subsection is its own paragraph, up to where the next section begins.
    """
    match = re.search(
        r'<p class="section">\s*<a name="[^"]*"></a>\s*<b>\s*'
        + re.escape(section)
        + r'\s*</b>(.*?)(?=<p class="section">)',
        content,
        re.S,
    )
    if not match:
        return {}
    body = CITATION_SPAN.sub(" ", MISNESTED_CLOSE.sub("</span></p>", match.group(1)))
    chunks = [body.split("<p", 1)[0]]
    chunks += re.findall(r'<p class="subsection">(.*?)</p>', body, re.S)

    out: dict[str, str] = {}
    for chunk in chunks:
        text = strip_tags(chunk)
        numbered = re.match(r"\(([\d.]+)\)\s*(.+)", text)
        if numbered:
            out[numbered.group(1)] = numbered.group(2).strip()
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    print("Fetching the Provincial Parks and Conservation Reserves Act, 2006 …",
          flush=True)
    document = fetch_statute()
    content = document.get("content") or ""
    if not content:
        print("e-Laws returned no content", file=sys.stderr)
        return 1

    parsed: dict[str, dict] = {}
    wrong: list[str] = []
    cache: dict[str, dict[str, str]] = {}
    for (section, sub), (key, phrase) in WANTED.items():
        if section not in cache:
            cache[section] = subsections(content, section)
        text = cache[section].get(sub) or ""
        if phrase.lower() not in text.lower():
            wrong.append(f"s. {section} ({sub}) [{key}] got: {text[:120]!r}")
            continue
        parsed[key] = {
            "subsection": f"{section} ({sub})",
            "text": text,
        }

    if wrong:
        print(
            "The Act no longer reads as expected, so no rule file was written "
            "rather than one the app would state as law:\n  "
            + "\n  ".join(wrong),
            file=sys.stderr,
        )
        return 1

    currency = str(document.get("dateFrom") or "")[:10]
    payload = {
        "statute": "S.O. 2006, c. 12",
        "title": "Provincial Parks and Conservation Reserves Act, 2006",
        "citation": CITATION,
        "source": SOURCE_PAGE,
        "api_source": API,
        "license": "OGL-Ontario",
        "license_url": "https://www.ontario.ca/page/open-government-licence-ontario",
        "currency_date": currency,
        "provisions": parsed,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    for key, value in parsed.items():
        print(f"  s. {value['subsection']:9s} {key}: {value['text'][:80]}…")
    print(f"Wrote {args.out} (consolidated {currency})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
