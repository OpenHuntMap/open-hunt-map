# Publishing offline packs

Province overlay packs are static ZIP files built by:

```powershell
cd tools\gis
python build_pack.py on qc
```

Outputs:
- `packs/on-overlays.zip`
- `packs/qc-overlays.zip`

## App install (Android / iOS)

1. **Import ZIP:** Offline packs → Import ZIP → select `packs/on-overlays.zip` on a device/emulator build.
2. **Download:** the rolling `packs-latest` release hosts the zips, and
   `data/provinces.json` points at:
   - `https://github.com/OpenWoodsMap/open-woods-map/releases/download/packs-latest/on-overlays.zip`
   - `https://github.com/OpenWoodsMap/open-woods-map/releases/download/packs-latest/qc-overlays.zip`

Publishing an updated pack means overwriting the assets on that tag rather than
cutting a new one, so shipped builds pick the pack up without an app update:

```powershell
gh release upload packs-latest packs/on-overlays.zip packs/qc-overlays.zip --clobber
```

**The repository must be public for this to work.** GitHub serves release assets
from a private repository only to authenticated callers, and the app sends no
credentials, so Download fails with `HTTP 404` while the repo is private. Import
ZIP still works, since it never leaves the device.

## Basemap areas

Province packs cover the data layers. The basemap tiles under them are a
separate thing, saved on device from Offline packs → *Save an area for offline
use*, and there is nothing to publish: the tiles come straight from the same
endpoints the live map uses.

These are MapLibre's own offline regions, which buys tile deduplication,
reference counting across areas, resumable progress and real byte counts for
free. Three parts of the app exist because of how that API behaves:

- **`style_server_io.dart`** serves the style over `127.0.0.1`. MapLibre
  resolves a region's style through its *network* file source, which rejects
  `asset://` and `file://` outright
  ([maplibre-native#609](https://github.com/maplibre/maplibre-native/issues/609)),
  so a bundled style cannot be handed to it directly. Hosting a copy on the web
  would work but would put a second, drifting copy of the style in front of the
  one we ship. Android and iOS both need an explicit cleartext exemption for
  loopback; see `network_security_config.xml` and `Info.plist`.
- **`pruneStyleToArea`** strips sources the area cannot reach before handing the
  style over. MapLibre ignores each source's `bounds` while walking a region
  ([maplibre-native#4192](https://github.com/maplibre/maplibre-native/issues/4192)),
  so an area in northwestern Ontario would otherwise spend the whole download
  asking Quebec's imagery server for tiles it has never had.
- **`setOfflineTileCountLimit`** is raised on first use. The default is 6000
  tiles across all regions, and one Standard-detail area goes straight through
  it — silently, with the download simply stopping.

### Why downloads look stuck, and why resume re-downloads

A Hybrid area draws on four sources at once, so a deep one asks for thousands of
tiles in a couple of minutes and earns an HTTP 429 from the free endpoints:

```
W OfflineManagerUtils: offline download error, the SDK will retry
  (reason REASON_RATE_LIMIT): HTTP status code 429
```

MapLibre retries a rate-limited request on a growing backoff, so the download
does not fail, it crawls. To someone watching a progress bar that is
indistinguishable from being stuck, which is exactly how it was reported. Hence
`_maxConcurrentRequests` and `_maxRequestsPerHost` at 4 and 2 rather than 6 and
3, and hence the honest wording on the progress card. These are free public
services, two of them run by provincial governments, so being slowed down is the
correct answer to asking for too much rather than a bug to engineer around.

`BasemapAreaStore` is a singleton whose loopback server outlives the screen,
because leaving Offline packs used to close the server out from under the running
downloader, stall it, and leave the area marked incomplete through no fault of
the user. A screen arriving mid-download re-attaches to the progress stream
instead of starting a second one; `OfflineRegionStatus` exposes no download
state, so the store's own bookkeeping is the only way to know something is
already running.

`resume` starts a fresh region over the same ground rather than calling
`resumeOfflineRegionDownload`. A region records the style URL it was created
with, and for the asset basemaps that is a loopback address whose port dies with
the process, so a resumed region would fetch its style from nowhere. Tiles
already in the offline database are reference-counted and get satisfied without
network, so nothing already downloaded is fetched twice, and the old region is
dropped once the replacement exists.

`replace`, behind *Edit extent and detail*, is the same move with one rule
changed. Resume drops the old region even when the download fails, because the
replacement covers at least the same ground. An edit may shrink an area or lower
its detail, so a download that died partway is not guaranteed to hold what the
old region did; there the old region survives and the user sorts out two areas
rather than quietly ending up with less map. Because the download happens while
the old region is still on disk, its tiles are reused, and the size estimate
counts the area being edited among the coverage it discounts — a shrink honestly
reports fetching nothing. It also clears the ambient cache afterwards, for the
reason `delete` does: an edit made to reclaim space frees nothing the user can
see while the cache holds its own reference to the tiles the area let go.

Rendering is unaffected by any of this: the app draws the full bundled style,
and MapLibre matches cached resources by URL, so tiles fetched under the pruned
style are the same tiles the live map asks for.

## Regenerating Ontario GIS

```powershell
cd tools\gis
python convert_municlow.py          # needs _tmp_municlow shapefile extract
python fetch_wmu_parks_on.py
python convert_clupapro.py          # needs CLUPAPRO.zip extract under _tmp_clupapro
python build_pack.py on
```

Then sync into the Flutter app:

```powershell
powershell -File scripts\sync_assets.ps1
```
