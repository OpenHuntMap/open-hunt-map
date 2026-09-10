import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../map/basemap.dart';
import 'basemap_sources.dart';
import 'offline_db_size.dart';
import 'style_server.dart';
import 'tile_math.dart';

/// Marks a MapLibre offline region as one of ours. The offline database is
/// shared with the ambient tile cache and with anything else that ever wrote to
/// it, so the list has to be filtered rather than trusted.
const String _ownerKey = 'openwoodsmap';
const String _ownerValue = 'basemap-area';

/// MapLibre refuses to store more than this many tiles across all regions, and
/// silently stops a download that would exceed it. The default is 6000, which
/// one modest area blows straight through.
///
/// This is a backstop, not the real guard: the estimate shown before a download
/// is what keeps a user from filling their phone.
const int _tileCountLimit = 500000;

/// Tile servers here are free public services, two of them run by provincial
/// governments. Downloads are the one thing this app does that hits them hard,
/// so they go out politely rather than as fast as the phone can manage.
///
/// These were 6 and 3, which earns an HTTP 429 partway through a Hybrid area:
/// that basemap draws on four sources at once, so a deep area asks for
/// thousands of tiles in a few minutes. MapLibre retries a rate-limited request
/// with a growing backoff, so the download does not fail, it crawls, and to a
/// user watching a progress bar that is indistinguishable from being stuck.
const int _maxConcurrentRequests = 4;
const int _maxRequestsPerHost = 2;

/// An area of a basemap saved for offline use.
class BasemapArea {
  const BasemapArea({
    required this.regionId,
    required this.name,
    required this.basemap,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.sourceIds,
    required this.sizeBytes,
    required this.complete,
    this.createdAt,
  });

  final int regionId;
  final String name;
  final BasemapKind basemap;
  final LatLngBounds bounds;
  final int minZoom;
  final int maxZoom;
  final Set<String> sourceIds;

  /// What this area's tiles weigh. Tiles shared with another area are counted
  /// in both, so these do not sum to the figure from [offlineDatabaseBytes].
  final int sizeBytes;

  /// False when a download was interrupted. The tiles that did arrive are still
  /// usable, so the area is kept and flagged rather than discarded.
  final bool complete;

  final DateTime? createdAt;

  ExistingCoverage get coverage => ExistingCoverage(
        sourceIds: sourceIds,
        bounds: bounds,
        minZoom: minZoom,
        maxZoom: maxZoom,
      );
}

/// Whether a download of [bounds] at [maxZoom] on [basemap] would leave nothing
/// of [area] behind.
///
/// Plain degree comparisons: both rectangles come from the picker frame, so
/// they are axis-aligned, and nothing this app covers goes near the
/// antimeridian.
bool areaSupersedes(
  BasemapArea area, {
  required BasemapKind basemap,
  required LatLngBounds bounds,
  required int maxZoom,
}) {
  if (basemap != area.basemap || maxZoom < area.maxZoom) return false;
  return bounds.southwest.latitude <= area.bounds.southwest.latitude &&
      bounds.southwest.longitude <= area.bounds.southwest.longitude &&
      bounds.northeast.latitude >= area.bounds.northeast.latitude &&
      bounds.northeast.longitude >= area.bounds.northeast.longitude;
}

/// Progress of an in-flight download.
class AreaDownloadProgress {
  const AreaDownloadProgress({
    required this.fraction,
    required this.bytes,
    required this.tilesDone,
    required this.tilesTotal,
  });

  final double fraction;
  final int bytes;
  final int tilesDone;
  final int tilesTotal;
}

/// Creates, lists and deletes offline basemap areas.
///
/// A single shared instance, because a download outlives the screen that
/// started it. The native downloader keeps reading the style as it works, so the
/// loopback server has to stay up, and whatever screen is on top afterwards
/// needs to be able to ask what is still running rather than start it twice.
class BasemapAreaStore {
  BasemapAreaStore._();

  static final BasemapAreaStore instance = BasemapAreaStore._();

  final StyleServer _styleServer = StyleServer();
  bool _configured = false;

  final StreamController<AreaDownloadProgress?> _progress =
      StreamController<AreaDownloadProgress?>.broadcast();

  int _active = 0;
  AreaDownloadProgress? _latest;
  String? _downloadingName;

  /// Progress of the running download, or null between downloads.
  Stream<AreaDownloadProgress?> get progress => _progress.stream;

  /// The most recent progress report, for a screen that arrives mid-download and
  /// has no event to wait for yet.
  AreaDownloadProgress? get latestProgress => _latest;

  /// Name of the area being downloaded, or null if nothing is running.
  String? get downloadingName => _downloadingName;

  bool get isDownloading => _active > 0;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    await setOfflineTileCountLimit(_tileCountLimit);
    await setOfflineMaxConcurrentRequests(
      maxRequests: _maxConcurrentRequests,
      maxRequestsPerHost: _maxRequestsPerHost,
    );
  }

  /// Every area this app has saved, newest first.
  Future<List<BasemapArea>> list() async {
    final regions = await getListOfRegions();
    final areas = <BasemapArea>[];
    for (final region in regions) {
      if (region.metadata[_ownerKey] != _ownerValue) continue;
      final basemap = _basemapFrom(region.metadata['basemap'] as String?);
      if (basemap == null) continue;

      var bytes = 0;
      var complete = false;
      try {
        final status = await getOfflineRegionStatus(region.id);
        bytes = status.completedResourceSize;
        complete = status.isComplete;
      } on Object {
        // A region whose status cannot be read is still a region; showing it
        // without a size beats hiding storage the user is paying for.
      }

      areas.add(
        BasemapArea(
          regionId: region.id,
          name: (region.metadata['name'] as String?) ?? 'Saved area',
          basemap: basemap,
          bounds: region.definition.bounds,
          minZoom: region.definition.minZoom.round(),
          maxZoom: region.definition.maxZoom.round(),
          sourceIds: _sourceIdsFrom(region.metadata['sources'] as String?),
          sizeBytes: bytes,
          complete: complete,
          createdAt: DateTime.tryParse(
            (region.metadata['created'] as String?) ?? '',
          ),
        ),
      );
    }
    areas.sort((a, b) {
      final left = a.createdAt;
      final right = b.createdAt;
      if (left == null || right == null) return b.regionId.compareTo(a.regionId);
      return right.compareTo(left);
    });
    return areas;
  }

  /// Total bytes the offline tile store occupies on the device.
  Future<int?> diskBytes() => offlineDatabaseBytes();

  /// The sources a basemap would download, for the estimate and for the
  /// overlap discount.
  Future<List<TileSourceSpec>> sourcesFor(BasemapKind basemap) async {
    final asset = basemap.assetStylePath;
    if (asset == null) return remoteSourceSpecs(basemap);
    return sourceSpecsFromStyle(await rootBundle.loadString(asset));
  }

  /// Downloads [bounds] of [basemap] and returns the saved area.
  ///
  /// Completes when the download finishes or fails; [onProgress] reports along
  /// the way.
  Future<BasemapArea> download({
    required String name,
    required BasemapKind basemap,
    required LatLngBounds bounds,
    required int maxZoom,
    void Function(AreaDownloadProgress progress)? onProgress,
    void Function(int regionId)? onRegionCreated,
  }) async {
    await _configure();
    _active++;
    _downloadingName = name;

    final asset = basemap.assetStylePath;
    final String styleUrl;
    final List<TileSourceSpec> sources;
    if (asset == null) {
      final remote = basemap.remoteStyleUrl;
      if (remote == null) {
        throw StateError('${basemap.label} has no style to download.');
      }
      styleUrl = remote;
      sources = remoteSourceSpecs(basemap);
    } else {
      final style = await rootBundle.loadString(asset);
      final pruned = pruneStyleToArea(style, bounds);
      styleUrl = await _styleServer.serve(pruned);
      sources = sourceSpecsFromStyle(pruned);
    }

    final definition = OfflineRegionDefinition(
      bounds: bounds,
      mapStyleUrl: styleUrl,
      minZoom: minOfflineZoom.toDouble(),
      maxZoom: maxZoom.toDouble(),
    );

    var lastBytes = 0;
    // downloadOfflineRegion resolves once the download has *started*, so the
    // terminal event is the only thing that says it is done. Returning on the
    // call itself would close the style server out from under the downloader
    // and tell the user the area was saved before a single tile had arrived.
    final finished = Completer<void>();

    try {
      final region = await downloadOfflineRegion(
        definition,
        metadata: {
          _ownerKey: _ownerValue,
          'name': name,
          'basemap': basemap.name,
          'sources': sources.map((source) => source.id).join(','),
          'created': DateTime.now().toUtc().toIso8601String(),
        },
        onEvent: (event) {
          switch (event) {
            case InProgress():
              lastBytes = event.completedResourceSize;
              final report = AreaDownloadProgress(
                fraction: (event.progress / 100).clamp(0.0, 1.0),
                bytes: event.completedResourceSize,
                tilesDone: event.completedResourceCount,
                tilesTotal: event.requiredResourceCount,
              );
              _latest = report;
              _progress.add(report);
              onProgress?.call(report);
            case Success():
              if (!finished.isCompleted) finished.complete();
            case Error():
              if (!finished.isCompleted) finished.completeError(event.cause);
          }
        },
      );
      onRegionCreated?.call(region.id);
      await finished.future;

      return BasemapArea(
        regionId: region.id,
        name: name,
        basemap: basemap,
        bounds: bounds,
        minZoom: minOfflineZoom,
        maxZoom: maxZoom,
        sourceIds: sources.map((source) => source.id).toSet(),
        sizeBytes: lastBytes,
        complete: true,
        createdAt: DateTime.now(),
      );
    } finally {
      _active--;
      if (_active == 0) {
        _downloadingName = null;
        _latest = null;
        _progress.add(null);
        // The pruned style is only needed while the downloader is reading it.
        await _styleServer.close();
      }
    }
  }

  /// Picks an interrupted area back up, returning the completed area.
  ///
  /// This starts a fresh region over the same ground rather than calling
  /// [resumeOfflineRegionDownload]. A region records the style URL it was built
  /// with, and for the asset basemaps that is a loopback address whose port dies
  /// with the process, so a resumed region would fetch its style from nowhere.
  /// Tiles already in the offline database are reference-counted and get
  /// satisfied without touching the network, so the bytes already downloaded are
  /// kept either way.
  Future<BasemapArea> resume(
    BasemapArea area, {
    void Function(AreaDownloadProgress progress)? onProgress,
  }) async {
    int? replacement;
    try {
      return await download(
        name: area.name,
        basemap: area.basemap,
        bounds: area.bounds,
        maxZoom: area.maxZoom,
        onProgress: onProgress,
        onRegionCreated: (id) => replacement = id,
      );
    } finally {
      // Drop the old region once something is holding its tiles, including when
      // this attempt also failed: the replacement covers the same ground and has
      // at least as much of it, so keeping both would only show the user the
      // same area twice.
      if (replacement != null && replacement != area.regionId) {
        await deleteOfflineRegion(area.regionId);
      }
    }
  }

  /// Changes a saved area's extent, detail level or basemap, returning the area
  /// as it now stands.
  ///
  /// The new definition is downloaded and the old region dropped afterwards,
  /// because MapLibre offers no way to move a region's bounds or widen its zoom
  /// range in place. That costs less than it sounds: tiles in the offline
  /// database are reference-counted, so everything the old area already held
  /// inside the new extent is satisfied without touching the network, and only
  /// the ground the edit added is fetched. The fresh region is also what makes
  /// this work at all for the asset basemaps, for the reason [resume]
  /// describes: a region remembers a loopback style URL whose port is gone.
  Future<BasemapArea> replace(
    BasemapArea area, {
    required String name,
    required BasemapKind basemap,
    required LatLngBounds bounds,
    required int maxZoom,
    void Function(AreaDownloadProgress progress)? onProgress,
  }) async {
    int? replacement;
    var saved = false;
    try {
      final updated = await download(
        name: name,
        basemap: basemap,
        bounds: bounds,
        maxZoom: maxZoom,
        onProgress: onProgress,
        onRegionCreated: (id) => replacement = id,
      );
      saved = true;
      return updated;
    } finally {
      // A resume can drop the old region even when it fails, because the
      // replacement covers the same ground. An edit cannot: it is allowed to
      // shrink an area or lower its detail, so a download that died partway
      // through is not guaranteed to hold what the old region did. Where it
      // does not, the old one stays and the user is left two areas to sort out
      // rather than quietly less map than they started with.
      if (replacement != null &&
          replacement != area.regionId &&
          (saved ||
              areaSupersedes(
                area,
                basemap: basemap,
                bounds: bounds,
                maxZoom: maxZoom,
              ))) {
        // delete() rather than deleteOfflineRegion(), for the ambient cache
        // reason it documents: an edit that shrinks an area or drops its detail
        // is often made to reclaim space, and the tiles it lets go are not
        // really gone while the cache still holds its own reference to them.
        await delete(area.regionId);
      }
    }
  }

  /// Renames a saved area, keeping its tiles.
  ///
  /// Metadata is replaced wholesale rather than patched, so everything the area
  /// needs to be recognised and resumed later has to be written back too.
  Future<void> rename(BasemapArea area, String name) async {
    await updateOfflineRegionMetadata(area.regionId, {
      _ownerKey: _ownerValue,
      'name': name,
      'basemap': area.basemap.name,
      'sources': area.sourceIds.join(','),
      'created':
          (area.createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    });
  }

  Future<void> delete(int regionId) async {
    await deleteOfflineRegion(regionId);
    // Tiles the region held are only really gone once the ambient cache stops
    // holding its own reference to them, otherwise deleting an area frees
    // nothing the user can see.
    await clearAmbientCache();
  }

  /// Releases the loopback server if nothing is downloading.
  ///
  /// Leaving the offline screen used to abandon the download outright: closing
  /// the server pulled the style out from under the native downloader, which then
  /// stalled and left the area marked incomplete through no fault of the user.
  Future<void> releaseIfIdle() async {
    if (_active > 0) return;
    await _styleServer.close();
  }

  static BasemapKind? _basemapFrom(String? name) {
    for (final kind in BasemapKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  static Set<String> _sourceIdsFrom(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    return raw.split(',').where((id) => id.isNotEmpty).toSet();
  }
}
