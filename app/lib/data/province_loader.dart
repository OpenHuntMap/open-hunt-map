import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../offline/offline_pack_store.dart';
import 'gazetteer.dart';
import 'geojson_header.dart';
import 'models.dart';
import 'seasons.dart';

class ProvinceData {
  const ProvinceData({
    required this.manifest,
    required this.layers,
    this.seasons,
  });

  final ProvinceManifest manifest;
  final Map<String, LoadedLayer> layers;
  final ProvinceSeasons? seasons;
}

/// Thrown when a province has no installed pack. Overlays are never bundled in
/// the binary, so this is the normal first-run state rather than an error.
class PackNotInstalled implements Exception {
  const PackNotInstalled(this.provinceId);

  final String provinceId;

  @override
  String toString() => 'No offline pack installed for $provinceId.';
}

/// Parses an index off the main isolate.
///
/// Top-level because [compute] needs it to be. Ontario is 2.2 MB of JSON and
/// Quebec 5.1 MB, and folding every name for search on top of decoding that is
/// well past a frame's budget.
GazetteerIndex _parseGazetteer(String jsonText) =>
    GazetteerIndex.parse(jsonText);

class ProvinceLoader {
  static const assetRoot = 'assets/data';

  /// One parsed index per province, keyed by what the pack says it is.
  ///
  /// Parsing costs too much to repeat every time the search sheet opens, and
  /// the index outlives the sheet. The key carries the pack version and record
  /// count so re-importing a pack mid-session is picked up rather than served
  /// from a cache of the pack that was replaced.
  final Map<String, ({String key, GazetteerResult result})> _gazetteers = {};

  Future<List<Province>> loadProvinces() async {
    final json = await _loadAssetJson('$assetRoot/provinces.json');
    return (json['provinces'] as List<dynamic>? ?? const [])
        .map((item) => Province.fromJson(item as Map<String, dynamic>))
        .where((province) => province.enabled)
        .toList();
  }

  /// Where the list of published packs lives, or null if the asset omits it.
  ///
  /// Alongside the pack URLs rather than compiled in, so the index can move
  /// without an app update. Null is a supported answer: the Offline packs screen
  /// then behaves exactly as it does with no signal.
  Future<String?> loadPackIndexUrl() async {
    final json = await _loadAssetJson('$assetRoot/provinces.json');
    return switch (json['packIndexUrl']) {
      final String url when url.trim().isNotEmpty => url.trim(),
      _ => null,
    };
  }

  /// Loads the installed pack for [provinceId].
  ///
  /// Throws [PackNotInstalled] when nothing has been downloaded yet; callers
  /// should send the user to the Offline packs screen.
  Future<ProvinceData> loadProvince(String provinceId) async {
    final id = provinceId.toLowerCase();
    if (!await hasOfflinePack(id)) throw PackNotInstalled(id);

    final manifest = ProvinceManifest.fromJson(
      await _loadPackJson(id, 'manifest.json'),
    );
    final entries = await Future.wait(manifest.layers.map((layer) async {
      final filePath = await offlinePackFilePath(id, layer.path);
      if (filePath == null) {
        throw StateError(
          'Installed pack for $id is missing ${layer.path}.',
        );
      }
      return MapEntry(
        layer.id,
        LoadedLayer(
          manifest: layer,
          metadata: geoJsonMetadata(
            await readOfflinePackHead(id, layer.path),
          ),
          sourceUri: Uri.file(filePath).toString(),
        ),
      );
    }));
    return ProvinceData(
      manifest: manifest,
      layers: Map.fromEntries(entries),
      seasons: await _loadSeasons(id),
    );
  }

  Future<ProvinceSeasons?> _loadSeasons(String provinceId) async {
    // Regulation years run spring-to-spring, so in Jan-Mar the pack still
    // carries last calendar year's file.
    final now = DateTime.now();
    final years = {now.year, now.year - 1, now.year + 1}.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final relative in [
      for (final year in years) 'seasons/$year.json',
      'seasons/current.json',
    ]) {
      final text = await readOfflinePackText(provinceId, relative);
      if (text == null) continue;
      try {
        return ProvinceSeasons.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Loads the place-name index for [provinceId], or says why it cannot.
  ///
  /// Never called from startup. The index is only needed once the user opens
  /// search, and reading a few megabytes to decide whether the map can draw
  /// would be a cost paid by everyone who never searches.
  ///
  /// Every failure here is a reportable state rather than an exception,
  /// because none of them should cost the user coordinate search: no pack
  /// installed is the first-run state, a pack that declares no index is simply
  /// an older pack, and a declared index that will not parse is a bad build
  /// that the sheet has to survive.
  Future<GazetteerResult> loadGazetteer(String provinceId) async {
    final id = provinceId.toLowerCase();
    if (!await hasOfflinePack(id)) {
      return const GazetteerResult(GazetteerAvailability.noPack);
    }

    final GazetteerManifest? declared;
    try {
      declared =
          ProvinceManifest.fromJson(await _loadPackJson(id, 'manifest.json'))
              .gazetteer;
    } catch (_) {
      return const GazetteerResult(GazetteerAvailability.unreadable);
    }
    if (declared == null || declared.path.isEmpty) {
      return const GazetteerResult(GazetteerAvailability.notInPack);
    }

    final key = '${declared.path}|${declared.recordCount}';
    if (_gazetteers[id] case (key: final cached, result: final result)
        when cached == key) {
      return result;
    }

    final text = await readOfflinePackText(id, declared.path);
    final result = switch (text) {
      // Declared but absent is a damaged pack, not an old one. Saying "built
      // before this search existed" here would be inventing a reason.
      null => const GazetteerResult(GazetteerAvailability.unreadable),
      final json => await _parse(json),
    };
    _gazetteers[id] = (key: key, result: result);
    return result;
  }

  Future<GazetteerResult> _parse(String json) async {
    try {
      return GazetteerResult(
        GazetteerAvailability.ready,
        index: await compute(_parseGazetteer, json),
      );
    } catch (_) {
      return const GazetteerResult(GazetteerAvailability.unreadable);
    }
  }

  /// The installed pack's manifest on its own, or null when there is none.
  ///
  /// Separate from [loadProvince] because the Offline packs screen only wants
  /// what the pack says about itself. [loadProvince] resolves a file path and
  /// reads a header for every layer, which is work worth doing to draw a map and
  /// not to print a build date. Returns null rather than throwing on an
  /// unreadable manifest: the screen's job is to offer a download, and it can
  /// still do that for a pack it cannot describe.
  Future<ProvinceManifest?> loadInstalledManifest(String provinceId) async {
    final id = provinceId.toLowerCase();
    if (!await hasOfflinePack(id)) return null;
    try {
      return ProvinceManifest.fromJson(await _loadPackJson(id, 'manifest.json'));
    } catch (_) {
      return null;
    }
  }

  Future<String?> loadPolicy(String provinceId, String policyId) =>
      readOfflinePackText(provinceId.toLowerCase(), 'policies/$policyId.md');

  Future<bool> hasProvinceData(String provinceId) =>
      hasOfflinePack(provinceId.toLowerCase());

  Future<Map<String, dynamic>> _loadAssetJson(String path) async {
    final text = await rootBundle.loadString(path);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _loadPackJson(
    String provinceId,
    String relativePath,
  ) async {
    final text = await readOfflinePackText(provinceId, relativePath);
    if (text == null) {
      throw StateError(
        'Installed pack for $provinceId is missing $relativePath.',
      );
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }
}
