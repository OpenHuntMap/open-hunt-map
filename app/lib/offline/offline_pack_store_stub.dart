import 'dart:typed_data';

const offlinePackStorageSupported = false;

Future<Set<String>> installedOfflinePackIds() async => {};

Future<bool> hasOfflinePack(String provinceId) async => false;

Future<String?> readOfflinePackText(
  String provinceId,
  String relativePath,
) async =>
    null;

Future<String?> offlinePackFilePath(
  String provinceId,
  String relativePath,
) async =>
    null;

Future<String?> readOfflinePackHead(
  String provinceId,
  String relativePath, {
  int maxBytes = 64 * 1024,
}) async =>
    null;

Future<String> installOfflinePack(
  String provinceId,
  Uint8List zipBytes,
) =>
    Future.error(
      UnsupportedError(
        'Offline pack installation is available on mobile and desktop.',
      ),
    );

Future<void> deleteOfflinePack(String provinceId) async {}
