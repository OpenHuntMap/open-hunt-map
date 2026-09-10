# OpenWoodsMap

Offline-first Canadian land map for **Android and iOS**: Crown land, parks, WMUs, and municipalities — with tap-to-identify Land Info (local government + land-use report). No accounts, no servers, no paid map APIs. Free, and no paywall ever.

Anyone heading out needs the same two things: a map that works with no signal, and a straight answer about whose land they are standing on. That part serves hikers, anglers and hunters alike. On top of it, the deepest work so far is hunting legality — seasons, closures and the regulations behind them — because that is where a wrong answer costs the most. Hiking- and fishing-specific features are not built yet, and this README will say so until they are.

**Stack:** Flutter + MapLibre · GeoJSON · zero-infra (app bundle + GitHub Releases)

**Targets:** Android + iOS only. On a Windows/Mac/Linux PC, run the Android build in an emulator such as [BlueStacks](https://www.bluestacks.com/) or Android Studio’s emulator.

## Quick start

```powershell
$env:PATH = "C:\_stuff\dev\tools\flutter\bin;$env:PATH"
cd C:\_stuff\dev\open-woods-map
powershell -File scripts\sync_assets.ps1
cd app
flutter pub get
flutter run   # Android device, emulator, or iOS Simulator (on macOS)
```

Build a sideload APK: [docs/android_apk.md](docs/android_apk.md).

## Features

- Province switcher (Ontario, plus Quebec flagged **preview** — real zones and
  boundaries, but no seasons or policies yet)
- Overlay toggles (crown land, municipal & county forests, conservation
  authority land, reserves, parks, Crown game preserves, federal wildlife areas
  and bird sanctuaries, defence property, WMU, Sunday gun hunting,
  municipalities)
- **Closures outrank tenure:** Crown game preserves, National Wildlife Areas,
  Migratory Bird Sanctuaries and National Defence property are drawn over Crown
  land and reported first, since hunting there is prohibited whatever the tenure
  underneath says. In a bird sanctuary possessing *any* firearm is itself an
  offence, which is the part a deer hunter walking through would not expect
- **Permission-required land is neither open nor closed:** 409 conservation
  authority properties name the authority to ask, and 203 reserves are reported
  as needing the First Nation's permission — an Ontario licence conveys no right
  of access to reserve land, which is a different answer from "prohibited" and
  is worded like one. Where the conservation authority source draws nothing the
  card says that its silence is not permission
- **Defence property, with the caveat:** 140 National Defence properties
  totalling 51,309 ha, including Petawawa, Borden and Meaford. Closed to public
  hunting, but some bases run their own controlled hunts, so the card links the
  property's federal record rather than naming programmes a pack cannot keep
  current
- **The Far North says why it is empty:** above the Far North line the policy
  atlas thins out to nothing, so a parcel with no policy report is reported as
  ground the atlas never reached rather than ground no policy applies to. Where
  one of the four community based land use plans covers the point, the card
  names it and links the document while making clear it is not a hunting
  regulation
- **Park permissions from the regulation, not guesswork:** hunting in an Ontario
  provincial park is prohibited unless O. Reg. 663/98 Part 3 opens it. Parks the
  regulation opens in whole read as permitted; the 35 it opens only a surveyed
  part of say so plainly, because the province describes that part in words and
  never mapped it. Carve-outs are quoted verbatim
- **Sunday gun hunting:** permitted north of the French and Mattawa rivers, and
  south of them only in the 193 jurisdictions the regulation schedules. The card
  says which case applies at the tapped point
- **Land Info:** tap anywhere for a three-tab card — *Land* (local government for
  bylaws, land tenure, designation, policy), *Seasons* and *Weather*. Land-use
  policies read offline from the pack, with a link to the official live report
- On-screen zoom buttons alongside pinch-zoom
- **Seasons:** every species with a published WMU season table, split into
  open now / upcoming / closed, filterable by game group and residency
- **Weather:** current conditions and wind direction for the tapped point, legal
  light times, best sits for the day, and a 7-day outlook. Includes an optional
  deer activity graph — an openly documented heuristic, not a prediction, with
  the reasons behind every hour shown and moon phase deliberately left out. The
  only feature that needs a connection
- Waypoints + GPS track recording; GPX / KML / GeoJSON import-export
- Opens on your own position, once per launch. If location is off or refused it
  falls back to the province without complaining, and switching basemaps keeps
  the view exactly where you left it
- Basemaps: offline / streets / satellite / hybrid. Satellite is provincial
  aerial photography over Ontario and Quebec with global Sentinel-2 elsewhere;
  hybrid stacks OpenFreeMap's roads, watercourses, boundaries and place names
  on top of it
- **Basemap areas:** save the ground you actually use for offline use, at a
  detail level you choose, with the size estimated before you commit and the
  overlap with anything already saved deducted from it
- **Province packs:** download from GitHub Releases or import a ZIP on device

### Province packs

Nothing province-specific is baked into the binary. Overlays, policies and
seasons all live in a downloadable pack, so data can be refreshed without a
store release and the app installs small.

### Basemap areas

Province packs make the *data* work offline. The basemap underneath it still
streams, so Streets, Satellite and Hybrid go blank without a signal. Saving an
area fixes that for the ground that matters to you.

Pick the area by framing it on the map, choose Overview, Standard or Detailed,
and the estimate updates as you pan. Tiles are shared between areas and between
basemaps, so re-saving somewhere you already have costs only the difference, and
the estimate says so. Storage is listed per basemap, alongside the true total on
disk — which is smaller than the sum of the parts wherever areas overlap.

Roughly what to expect for a phone-sized viewport of about 27 × 28 km:

| Detail | Good for | Satellite | Hybrid | Streets |
|--------|----------|-----------|--------|---------|
| Overview (z12) | Lakes, highways, towns | ~2 MB | ~4 MB | ~2 MB |
| Standard (z14) | Side roads and bush roads | ~20 MB | ~42 MB | ~22 MB |
| Detailed (z16) | Individual trees and trails | ~200 MB | ~220 MB | n/a |

Streets stops at Standard because OpenFreeMap's vector tiles stop at zoom 14;
the map still zooms in past that, it just stops gaining detail.

| Ontario layer | Approx. features |
|---------------|------------------|
| Crown land parcels (MNR unpatented + CLUPA) | ~42,700 |
| Municipalities | ~685 |
| Geographic townships | ~2,500 |
| Provincial parks | ~340 |
| WMUs | ~150 |
| Hunting seasons | 21 species across 150 WMUs |

## Docs

- [Architecture](docs/architecture.md)
- [Datasets](docs/datasets.md)
- [Constraints](docs/constraints.md)
- [AI guidelines](docs/ai_guidelines.md)
- [Contributing](docs/contributing.md)
- [Android APK](docs/android_apk.md)
- [Offline packs](docs/packs.md)
- [GIS pipeline](tools/gis/README.md)

## License

MIT — see [LICENSE](LICENSE).
