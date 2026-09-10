import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const offlinePackStorageSupported = true;
const _installedIdsKey = 'offline_pack_ids';
const _manifestPathKeyPrefix = 'offline_pack_manifest_';

Future<Directory> _packRoot() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(path.join(documents.path, 'offline_packs'));
}

Future<Directory> _packDirectory(String provinceId) async {
  final root = await _packRoot();
  return Directory(path.join(root.path, provinceId.toLowerCase()));
}

Future<Set<String>> installedOfflinePackIds() async {
  final preferences = await SharedPreferences.getInstance();
  final recorded = preferences.getStringList(_installedIdsKey) ?? const [];
  final installed = <String>{};
  for (final id in recorded) {
    if (await hasOfflinePack(id)) installed.add(id);
  }
  return installed;
}

Future<bool> hasOfflinePack(String provinceId) async {
  final preferences = await SharedPreferences.getInstance();
  final manifestPath =
      preferences.getString('$_manifestPathKeyPrefix${provinceId.toLowerCase()}');
  return manifestPath != null && await File(manifestPath).exists();
}

Future<String?> readOfflinePackText(
  String provinceId,
  String relativePath,
) async {
  final file = await _packFile(provinceId, relativePath);
  return file?.readAsString();
}

/// Absolute path of a file inside an installed pack, or null when it is absent.
///
/// Overlays are handed to MapLibre as a path so the renderer parses them in
/// native code. Decoding them in Dart and shipping them over the platform
/// channel copies every parcel onto the Android heap as well, which overruns
/// the per-app heap cap on modest devices.
Future<String?> offlinePackFilePath(
  String provinceId,
  String relativePath,
) async =>
    (await _packFile(provinceId, relativePath))?.path;

/// Reads at most [maxBytes] from the start of a pack file.
///
/// Overlay files write their `metadata` object ahead of `features`, so the
/// header carries everything the app needs about a layer without touching the
/// geometry behind it.
Future<String?> readOfflinePackHead(
  String provinceId,
  String relativePath, {
  int maxBytes = 64 * 1024,
}) async {
  final file = await _packFile(provinceId, relativePath);
  if (file == null) return null;
  final handle = await file.open();
  try {
    return utf8.decode(await handle.read(maxBytes), allowMalformed: true);
  } finally {
    await handle.close();
  }
}

Future<File?> _packFile(String provinceId, String relativePath) async {
  if (!_isSafeRelativePath(relativePath)) return null;
  final directory = await _packDirectory(provinceId);
  final file = File(path.joinAll([directory.path, ...relativePath.split('/')]));
  return await file.exists() ? file : null;
}

Future<String> installOfflinePack(
  String provinceId,
  Uint8List zipBytes,
) async {
  final id = provinceId.toLowerCase();
  final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
  final files = <String, ArchiveFile>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name.replaceAll('\\', '/');
    if (!_isSafeRelativePath(name)) {
      throw const FormatException('The ZIP contains an unsafe path.');
    }
    if (name == 'manifest.json' ||
        name.startsWith('overlays/') ||
        name.startsWith('policies/') ||
        name.startsWith('seasons/')) {
      files[name] = entry;
    }
  }

  final manifestFile = files['manifest.json'];
  if (manifestFile == null) {
    throw const FormatException('The ZIP does not contain manifest.json.');
  }
  final manifestBytes = manifestFile.readBytes();
  if (manifestBytes == null) {
    throw const FormatException('Could not read manifest.json.');
  }
  final manifest =
      jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
  if ((manifest['id'] as String?)?.toLowerCase() != id) {
    throw FormatException('This pack is not for ${id.toUpperCase()}.');
  }
  final layers = manifest['layers'] as List<dynamic>? ?? const [];
  for (final layer in layers) {
    final layerPath = (layer as Map<String, dynamic>)['path'] as String?;
    if (layerPath == null ||
        !layerPath.startsWith('overlays/') ||
        !files.containsKey(layerPath)) {
      throw FormatException('The pack is missing overlay "$layerPath".');
    }
  }

  final root = await _packRoot();
  await root.create(recursive: true);
  final staging = Directory(
    path.join(root.path, '.$id-installing-${DateTime.now().microsecondsSinceEpoch}'),
  );
  final destination = await _packDirectory(id);
  try {
    await staging.create(recursive: true);
    for (final MapEntry(key: relativePath, value: entry) in files.entries) {
      final bytes = entry.readBytes();
      if (bytes == null) {
        throw FormatException('Could not extract "$relativePath".');
      }
      final output = File(
        path.joinAll([staging.path, ...relativePath.split('/')]),
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes, flush: true);
      // Verifying the ZIP decompresses every entry up front, so release each
      // one once it is on disk instead of holding the whole pack in memory.
      entry.closeSync();
    }
    if (await destination.exists()) {
      await destination.delete(recursive: true);
    }
    await staging.rename(destination.path);
  } catch (_) {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }

  final manifestPath = path.join(destination.path, 'manifest.json');
  final preferences = await SharedPreferences.getInstance();
  final ids = preferences.getStringList(_installedIdsKey)?.toSet() ?? <String>{};
  ids.add(id);
  await preferences.setStringList(_installedIdsKey, ids.toList()..sort());
  await preferences.setString('$_manifestPathKeyPrefix$id', manifestPath);
  return manifestPath;
}

Future<void> deleteOfflinePack(String provinceId) async {
  final id = provinceId.toLowerCase();
  final directory = await _packDirectory(id);
  if (await directory.exists()) await directory.delete(recursive: true);

  final preferences = await SharedPreferences.getInstance();
  final ids = preferences.getStringList(_installedIdsKey)?.toSet() ?? <String>{};
  ids.remove(id);
  await preferences.setStringList(_installedIdsKey, ids.toList()..sort());
  await preferences.remove('$_manifestPathKeyPrefix$id');
}

bool _isSafeRelativePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains(':')) {
    return false;
  }
  final segments = value.split('/');
  return !segments.any(
    (segment) => segment.isEmpty || segment == '..' || segment == '.',
  );
}
