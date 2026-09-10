import 'dart:convert';

import 'package:flutter/services.dart';

import '../offline/offline_pack_store.dart';
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

class ProvinceLoader {
  static const assetRoot = 'assets/data';

  Future<List<Province>> loadProvinces() async {
    final json = await _loadAssetJson('$assetRoot/provinces.json');
    return (json['provinces'] as List<dynamic>? ?? const [])
        .map((item) => Province.fromJson(item as Map<String, dynamic>))
        .where((province) => province.enabled)
        .toList();
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
