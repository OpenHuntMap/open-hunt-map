# Contributing

## Setup

1. Clone the repo.
2. Install [Flutter 3.29+](https://docs.flutter.dev/get-started/install).
3. Sync GIS assets: `powershell -File scripts\sync_assets.ps1` (from repo root).
4. `cd app && flutter pub get`
5. `flutter run` on an **Android or iOS** device/emulator.

Supported product targets: **Android + iOS** only (Android emulators such as BlueStacks count). Web and native desktop are out of scope.

## Province packs

Add or extend `data/{cc}/`:

- `manifest.json` — layer ids and paths under `overlays/`
- `overlays/` — GeoJSON (or PMTiles) per layer
- `policies/` — optional static policy text/PDFs
- `seasons/` — optional curated season JSON (Ontario)
- Register province in `data/provinces.json` (`enabled`, `bbox`, `name`, optional `packUrl`)

Follow attribute expectations in [datasets.md](datasets.md) for Land Info. Build release ZIPs with `tools/gis/build_pack.py`.

### Automated geometry packs

- Workflow: `.github/workflows/rebuild-geometry-packs.yml` (monthly + manual).
- Entry script: `tools/gis/rebuild_geometry.py --pack`
- Download URL tag: `packs-latest` (see `packUrl` in `data/provinces.json`).
- Seasons/policies are **not** auto-scraped; refresh with `.agents/skills/refresh-seasons-policies` then re-pack.

## Data in git

- Keep clones light: prefer sample/regional fixtures in git when possible.
- Full province packs → **GitHub Releases**; link via `packUrl`.

## PR hygiene

- One logical change per PR (layer, UI, or docs).
- UI changes: check them on a device. [devtest.md](devtest.md) has an emulator
  harness if you want one, but `flutter run` is enough.
- Note data sources and licenses in the PR description.
- Do not commit secrets, API keys, or proprietary datasets.
- `flutter analyze` (and tests) before opening a PR.

## Constraints

All contributions must satisfy [constraints.md](constraints.md).
