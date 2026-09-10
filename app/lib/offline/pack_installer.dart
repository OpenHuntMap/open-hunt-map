import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import 'offline_pack_store.dart';

typedef DownloadProgress = void Function(double? progress);

class PackInstaller {
  PackInstaller({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<void> download(
    Province province, {
    DownloadProgress? onProgress,
  }) async {
    final packUrl = province.packUrl;
    if (packUrl == null) {
      throw StateError('No download URL is configured for ${province.name}.');
    }
    if (!offlinePackStorageSupported) {
      throw UnsupportedError(
        'Pack downloads require Android or iOS '
            '(MapLibre has no desktop target yet).',
      );
    }

    final request = http.Request('GET', Uri.parse(packUrl));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Download failed with HTTP ${response.statusCode}.',
        request.url,
      );
    }

    final bytes = BytesBuilder(copy: false);
    var received = 0;
    final total = response.contentLength;
    onProgress?.call(total == null ? null : 0);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      received += chunk.length;
      onProgress?.call(
        total == null || total == 0 ? null : received / total,
      );
    }
    await installOfflinePack(province.id, bytes.takeBytes());
    onProgress?.call(1);
  }

  Future<bool> importZip(Province province) async {
    if (!offlinePackStorageSupported) {
      throw UnsupportedError(
        'ZIP import requires Android or iOS '
            '(MapLibre has no desktop target yet).',
      );
    }
    // file_picker copies the chosen file to cache/file_picker/<name> and its
    // Android code skips the copy when that path already exists, so importing a
    // rebuilt pack under the name of one already imported hands back the previous
    // bytes and reports success. Nothing about that is visible to the user, and
    // the file name a pack ships under does not change between releases.
    await FilePicker.platform.clearTemporaryFiles();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null) return false;
    final picked = result.files.single;
    final Uint8List? bytes = picked.bytes;
    if (bytes == null) {
      throw StateError('Could not read the selected ZIP file.');
    }
    await installOfflinePack(province.id, bytes);
    // The cache copy is a second full pack, tens of megabytes of it, and the
    // installed one is now authoritative. Best-effort: leaving it behind wastes
    // space but the import itself has already succeeded.
    if (picked.path case final path?) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return true;
  }

  void close() => _client.close();
}
