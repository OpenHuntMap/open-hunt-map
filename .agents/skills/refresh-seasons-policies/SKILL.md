---
name: refresh-seasons-policies
description: >-
  Refresh OpenWoodsMap hunting seasons and/or policy markdown (not geometry). Use
  when the user asks to update seasons, regulations summary tables, policy
  markdown, or yearly ON/QC seasons packs.
disable-model-invocation: false
---

# Refresh seasons / policies (OpenWoodsMap)

Geometry overlays are rebuilt by GitHub Actions (`.github/workflows/rebuild-geometry-packs.yml`).
**This skill covers seasons and policy text only** — typically once per year, after
Ontario publishes the updated regulations summary (usually March).

## Seasons (Ontario)

Seasons are scraped from the open-season tables in the Ontario Hunting Regulations
Summary. Every species chapter with a WMU season table is covered: deer, moose,
black bear, elk, wild turkey, wolf/coyote, upland birds, hares, squirrels,
bullfrog and furbearers. Migratory birds are federal and are **not** included.

Preferred path — run the workflow, which scrapes and opens a PR for review:
**Actions → Refresh hunting seasons → Run workflow** (set the regulation year).

Local path:

```powershell
cd tools\gis
python scrape_seasons_on.py --year 2026
```

Then:

1. Read the script output. Any `WARN unmatched WMU token` line means a regulation
   table listed a unit that does not match `data/on/overlays/wmu.geojson`, and
   those rows were **dropped**. Fix `expand_token` or the WMU layer before
   shipping.
2. Check `units_without_seasons` in the output JSON — a unit appearing there
   should be genuinely absent from the summary, not a parsing failure.
3. Spot-check two or three WMUs in `data/on/seasons/{YEAR}.json` against the
   official tables, including one big-game and one small-game species.
4. Rebuild the pack: `python build_pack.py on`.
5. Publish: run **Rebuild geometry packs** with publish enabled, or
   `gh release upload packs-latest packs/on-overlays.zip --clobber`.

The scraper is layout-sensitive. If ontario.ca restructures the chapters, the run
prints zero rows for a species rather than silently producing wrong dates — treat
that as a hard failure, not a warning.

## Policies

- ON policy markdown is generated from the official CLUPA CSVs by
  `build_policies_on.py` (run as part of `rebuild_geometry.py`). Do not hand-edit
  the generated files.
- Keep the "not a legal instrument / verify regs" disclaimer in any new copy.
- `build_pack.py` already packs `policies/`.

## Quebec seasons

No builder yet. Quebec publishes seasons per zone de chasse; mirror the ON schema
(`seasons` list plus per-unit indexes) under `data/qc/seasons/` and the app loader
picks it up with no code change.

## Do not

- Run `rebuild_geometry.py` unless the user also wants geometry refreshed.
- Merge a scraped seasons diff without reviewing it against the official tables.
- Treat seasons as legal advice in UI copy.
