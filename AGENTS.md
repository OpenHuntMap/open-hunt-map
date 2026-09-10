# AGENTS.md

Instructions for AI coding agents working in this repo. Human contributors
should read [`docs/contributing.md`](docs/contributing.md) instead; nothing here
is required to contribute.

## What this is

OpenWoodsMap is an offline-first Flutter + MapLibre app for Canadians heading
outdoors. It answers whose land you are standing on and what the rules are
there, with no signal and no account. Ontario is real and reasonably complete.
Quebec is a preview. There is no backend and no budget: every data source is
free and openly licensed.

The land, waypoint, track, basemap and weather features serve hiking and
fishing as much as hunting. Hunting legality is simply where the work has gone
deepest so far, because that is where a wrong answer costs the most. Do not
write copy that implies hiking or fishing features exist before they do; that
is the same overclaiming the rule below forbids, wearing a marketing hat.

## The one rule that matters most

**Never invent data, and never let the app sound more certain than its
sources.** This app tells people where it is legal to fire a rifle. A confident
wrong answer is the worst possible failure, and it is worse than no answer.

In practice:

- No placeholder, sample, illustrative, or plausible-looking geometry, policy
  text, or season dates. If a source cannot supply it, ship the gap.
- Every layer carries `source`, `license`, and `license_url` in its metadata.
- Prefer authoritative provincial parcel data over OpenStreetMap for anything
  that implies a legal boundary. OSM is fine for context, never for tenure.
- When a boundary is approximate, say so in the data (`boundary_accuracy`), and
 the card warns on it. Not dashed: MapLibre documents `line-dasharray` as
 data-driven on the web only, so one layer cannot dash some parcels and not
 others on Android or iOS. Where a distinction has to be visible on the map
 itself, `fill-opacity` is data-driven on mobile and less ink means less known.
- Distinguish "the rule says no" from "we have no record". They are different
  answers and the UI words them differently.
- Uncertainty belongs in the UI, not just in a commit message.

## Hard constraints

Read [`docs/constraints.md`](docs/constraints.md) in full before designing
anything. The ones most often violated by accident:

- No servers, no accounts, no paid map or geocoding APIs.
- Core paths work offline: identify, layers, Land Info, seasons. Weather is the
  one deliberate exception, and it is optional, additive, and fails with a clear
  message rather than breaking the card.
- No province geometry is bundled in the app. Only `data/provinces.json` ships;
  everything else arrives as a downloaded pack.
- MapLibre only. Android and iOS only, including Android emulators such as
  BlueStacks.

## Repo map

| Path | What lives there |
| --- | --- |
| `app/lib/map/` | Map shell, overlay styling, Land Info sheet and its tabs |
| `app/lib/data/` | Manifest and feature models, province and seasons loading |
| `app/lib/offline/` | Pack download and install, plus offline basemap areas |
| `app/lib/weather/` | Open-Meteo client and the deer activity heuristic |
| `app/lib/waypoints/` | Local waypoint storage and import/export |
| `tools/gis/` | Python fetch and build scripts, one per source |
| `tools/devtest/` | Emulator harness for on-device sanity checks (`owm.ps1`) |
| `data/{cc}/` | Generated per-province manifest, overlays, policies, seasons |
| `docs/` | Constraints, architecture, datasets, packs, APK build, devtest |
| `.agents/skills/` | Agent skills, vendor-neutral location |

Generated overlays under `data/{cc}/overlays/` are gitignored. Do not commit
them, and do not commit the `_tmp*` archives the fetch scripts download.

## Commands

```powershell
# Analyze and test (both must be clean before you claim done)
cd app; flutter analyze; flutter test

# Check a change on a real device. First run needs one-time setup: see
# docs/devtest.md, which also lists the traps worth knowing before you
# trust a screenshot.
powershell -File tools\devtest\owm.ps1 boot
powershell -File tools\devtest\owm.ps1 install
powershell -File tools\devtest\owm.ps1 launch -Settle 25
powershell -File tools\devtest\owm.ps1 shot before-change

# Refresh the only bundled asset after editing data/provinces.json
powershell -File scripts\sync_assets.ps1

# Rebuild all province geometry from source (slow, large downloads)
python tools\gis\rebuild_geometry.py

# Package a province pack for release
python tools\gis\build_pack.py

# Release APKs, one per ABI; BlueStacks wants x86_64
cd app; flutter build apk --release --split-per-abi
```

## Conventions

**Dart.** Match the file you are editing. Prefer `switch` expressions and
pattern matching, `withValues(alpha:)` over the deprecated `withOpacity`, and
`const` constructors. Widgets stay private to their file unless reused.

**Python.** Standard library plus `requests`, `shapely`, `pyproj`. One script
per source, named `fetch_*`, `build_*`, or `convert_*`. Quantize coordinates and
drop repeated prose into layer metadata: pack size is a real constraint and
these files reach tens of megabytes.

**Comments.** Explain a constraint the code cannot show, such as why a weight
was chosen or which legal rule a threshold encodes. Do not narrate what the next
line does or where the code came from.

**Editorial judgement.** Where the app has to interpret rather than report, as
the deer activity heuristic does, document the reasoning and its evidence
honestly in the source, expose it in the UI, and let the user disable it.

## Before you finish

- `flutter analyze` and `flutter test` are clean.
- Anything you changed on screen has been looked at on a device, not assumed.
  [`docs/devtest.md`](docs/devtest.md) explains how, and why a passing test
  says nothing about what the map drew.
- New data-bearing code paths degrade gracefully with no network.
- Anything user-facing that carries uncertainty says so on screen.
- [`docs/datasets.md`](docs/datasets.md) reflects any source you added or
  changed, including its licence.
