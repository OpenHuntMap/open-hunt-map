# Flutter data assets

Only `provinces.json` (the province catalogue and pack download URLs) is bundled
in the binary. Overlays, land-use policies and hunting seasons ship as
downloadable province packs so the map data can be refreshed without an app
release, and so the binary stays small.

Sync it before running or building:

- Windows PowerShell: `.\scripts\sync_assets.ps1`
- macOS/Linux: `./scripts/sync_assets.sh`

The scripts replace this directory's generated data while preserving this
README. Source datasets remain authoritative under the repository's `data/`.
Build packs with `python tools/gis/build_pack.py on qc`.
