# GIS ingestion pipeline

Zero-infra tooling to validate, normalize, and optionally fetch province overlay layers for OpenWoodsMap. Outputs land in `data/{province}/` at the repo root.

**Principles:** free public data only, no cloud services, Windows-friendly Python scripts.

## Huntable Crown (Ontario)

```powershell
python fetch_unpatented_on.py          # MNR Unpatented Land → _tmp_patent/
python build_crown_on.py               # parcels + CLUPA attributes → crown_land.geojson
python build_policies_on.py            # one markdown file per CLUPA policy id
python scrape_seasons_on.py --year 2026 # all-species WMU seasons → data/on/seasons/2026.json
```

Optional: `python fetch_patent_on.py` caches Patent Land External (subtract is incomplete in towns; prefer unpatented intersect).

## Basemap tooling

Neither of these touches province geometry, and neither runs as part of a pack
build.

```powershell
python build_hybrid_style.py    # OpenFreeMap Liberty + imagery → app/assets/styles/hybrid.json
python measure_tile_sizes.py    # median bytes/tile per source, for the offline size estimate
```

`build_hybrid_style.py` regenerates a committed asset; run it when OpenFreeMap
changes the Liberty style, and commit the result. It exits with an error rather
than quietly dropping a layer that has been renamed upstream.

`measure_tile_sizes.py` prints medians to paste into `_averageTileBytes` in
`app/lib/offline/basemap_sources.dart`. Those numbers are the whole basis of the
"about N MB to download" figure, so they should come from the endpoints rather
than from an assumption.


| Tool | Required | Notes |
|------|----------|-------|
| Python 3.11+ | Yes | Tested on Windows PowerShell |
| pip + venv | Recommended | `python -m venv .venv` |
| [tippecanoe](https://github.com/felt/tippecanoe) | Optional | GeoJSON → MBTiles |
| [pmtiles CLI](https://github.com/protomaps/go-pmtiles) | Optional | MBTiles → PMTiles for MapLibre |

## Setup

```powershell
cd tools\gis
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Dependencies are intentionally minimal: `requests` (optional fetch) and `shapely` (geometry validation). GeoJSON is read/written with the standard library — no GeoPandas required.

## Province layout

```
data/
  provinces.json           # enabled provinces + bboxes
  on/
    manifest.json          # layer index (updated by build_overlays.py)
    overlays/
      crown_land.geojson
      wmu.geojson
      parks.geojson
      townships.geojson
      municipalities.geojson
      municipal_forest.geojson
      game_preserve.geojson
      sunday_gun.geojson
    rules/                 # hunting rules parsed from legal text
      reg663.json
    policies/              # static regulation PDFs / markdown
  qc/
    ...                    # same structure
```

Source registries live beside the scripts:

- `sources_on.json` — Ontario open data URLs (GeoHub, StatsCan, municipal notes)
- `sources_qc.json` — Quebec open data URLs (GAGQ, TRQ, StatsCan)

## Fresh fetches (real overlays)

```powershell
# Ontario
python parse_reg663_on.py             # O. Reg. 663/98: park openings + Sunday gun
python parse_federal_wildlife_regs.py # NWA + bird sanctuary prohibitions
python fetch_wmu_parks_on.py          # WMUs, and parks with their Part 3 permission
python fetch_agreement_forest_on.py   # county/municipal forest tracts (parcels)
python fetch_game_preserve_on.py      # Crown game preserves (no hunting)
python fetch_cpcad_on.py              # CA land (permit) + federal closures
python fetch_first_nations_on.py      # reserves (First Nation permission), CLSS
python fetch_defence_land_on.py       # National Defence property (closed), DFRP
python fetch_land_use_plan_on.py      # Far North boundary + community plans
python fetch_townships_on.py          # LIO Geographic Township Improved
python build_sunday_gun_on.py         # needs municipalities + townships first
python fetch_unpatented_on.py
python build_crown_on.py
python scrape_seasons_on.py --year 2026

# Quebec
python fetch_qc_real.py               # WMU + parks + ZEC/outfitter territories
python fetch_municipalities_qc.py     # StatsCan CSD (reprojects EPSG:3347 → WGS84)
```

Then: `python build_pack.py on qc` and `..\..\scripts\sync_assets.ps1`.

### CI geometry rebuild (recommended)

Orchestrator (ON + QC geometry only; seasons/policies unchanged):

```powershell
python rebuild_geometry.py --pack
```

GitHub Actions: `.github/workflows/rebuild-geometry-packs.yml`

- **Schedule:** 1st of each month (~every 4 weeks)
- **On-demand:** Actions → *Rebuild geometry packs* → Run workflow
- **Publishes:** mutable release tag `packs-latest` (`on-overlays.zip` / `qc-overlays.zip`)
- App `data/provinces.json` `packUrl` points at `packs-latest`

Seasons: run the **Refresh hunting seasons** workflow (or `scrape_seasons_on.py` locally). It scrapes every species chapter of the Ontario Hunting Regulations Summary and opens a PR for review rather than pushing. Policies are generated by `build_policies_on.py` during a geometry rebuild. After merging either, re-pack or re-run the geometry workflow so the zip picks up the new files. See `.cursor/skills/refresh-seasons-policies`.

## Pipeline

### 1. Validate & repack overlays (primary)

Normalizes existing GeoJSON, validates WGS84 coordinates, ensures Land Info properties, and refreshes `manifest.json`:

```powershell
python build_overlays.py --province on
python build_overlays.py --province qc
```

With download attempts (portal pages may not expose direct GeoJSON URLs yet):

```powershell
python build_overlays.py --province on --download
```

When downloads fail, the script **repacks** files already in `data/{province}/overlays/`.

### 2. Enrich crown land (Land Info)

Ensures `crown_land` features have `policy_id` and `summary`. Missing summaries are filled from designation templates:

```powershell
python enrich_land_info.py --province on
python enrich_land_info.py --province qc --dry-run
```

`build_overlays.py` runs enrichment automatically for the crown land layer.

### 3. Optional — PMTiles (large province packs)

For release-sized tiles, convert GeoJSON after step 1:

**Windows (PowerShell):**

```powershell
.\build_pmtiles.ps1 -Province on -Layer crown_land
```

**Git Bash / WSL:**

```bash
./build_pmtiles.sh on crown_land
```

Requires `tippecanoe` and `pmtiles` on `PATH`. Update `manifest.json` layer entries to `.pmtiles` when shipping large packs via GitHub Releases (see `docs/contributing.md`).

## Land Info attributes

These properties are preserved (and validated) for the offline identify sheet:

| Layer | Required properties |
|-------|---------------------|
| **crown_land** | `policy_id`, `designation`, `hunting_allowed`, `summary` |
| **wmu** | `wmu_id`, `name` |
| **parks** | `name`, `park_type`, `hunting_allowed`, `basis`, `hunting_extent`, `reg_schedule`, `reg_text` |
| **townships** | `name`, `type` |
| **municipalities** | `name`, `type` |
| **municipal_forest** | `name`, `owner_type`, `basis`, `area_ha`, `lot` |
| **game_preserve** | `name`, `hunting_allowed`, `basis` |
| **sunday_gun** | `name`, `listed_as`, `geographic_area`, `jurisdiction`, `sunday_gun`, `exception` |
| **conservation_authority** | `name`, `authority`, `owner`, `managed_by`, `permit_required`, `basis`, `management_plan` |
| **federal_closure** | `name`, `designation`, `hunting_allowed`, `basis`, `hunting_extent`, `reg_text`, `entry_prohibited`, `firearm_prohibited`, `citation` |
| **first_nations** | `name`, `designation`, `hunting_allowed` (always null), `basis`, `permit_required`, `boundary_accuracy`, `survey_accuracy` |
| **defence_land** | `name`, `designation`, `hunting_allowed`, `basis`, `custodian`, `area_ha`, `record_url` |
| **land_use_plan** | `name`, `plan_scope`, `basis`, `year_approved`, `record_url` |

All geometries are normalized with metadata `crs: EPSG:4326` (WGS84, GeoJSON default).

## Licenses

| Province | Registry field | Reference |
|----------|----------------|-----------|
| Ontario | `OGL-Ontario` | [Open Government Licence – Ontario](https://www.ontario.ca/page/open-government-licence-ontario) |
| Quebec | `Licence-ouverte-Quebec` | [Licence ouverte du Québec](https://www.donneesquebec.ca/fr/licence/) |
| StatsCan boundaries | (in attribution) | [Statistics Canada Open Licence](https://www.statcan.gc.ca/en/reference/licence) |

Attribution strings are copied into overlay metadata and the province manifest.

## Full provincial data

Run `build_overlays.py` to print the **fetch plan** for each layer (portal URLs, formats, notes). Wire direct download URLs in `sources_{province}.json` as they become available; shapefile/ZIP ingest can be added without changing the output layout.

Do not commit full-province PMTiles to git — publish via Releases only.
