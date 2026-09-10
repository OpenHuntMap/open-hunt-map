import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/offline/offline_pack_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The documents directory installs land in, pointed at a temporary directory so
/// a test can look at what actually reached disk.
class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// A minimal but valid pack whose one layer header carries [note], so two builds
/// of the "same" pack can be told apart by content rather than by size.
Uint8List packBytes(String note) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'manifest.json',
        jsonEncode({
          'id': 'on',
          'layers': [
            {'id': 'crown_land', 'path': 'overlays/crown_land.geojson'},
          ],
        }),
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'overlays/crown_land.geojson',
        jsonEncode({
          'type': 'FeatureCollection',
          'metadata': {'note': note},
          'features': <Object>[],
        }),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('owm-pack-test');
    PathProviderPlatform.instance = _Documents(documents.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  Future<String> installedNote() async {
    final text = await readOfflinePackText('on', 'overlays/crown_land.geojson');
    final json = jsonDecode(text!) as Map<String, dynamic>;
    return (json['metadata'] as Map<String, dynamic>)['note'] as String;
  }

  test('a first install lands on disk', () async {
    await installOfflinePack('on', packBytes('first'));
    expect(await hasOfflinePack('on'), isTrue);
    expect(await installedNote(), 'first');
  });

  // The one the app got wrong on a device: importing a rebuilt pack reported
  // success and left the previous data in place, which for this app means stale
  // seasons and boundaries presented as current.
  test('installing again replaces the data rather than keeping the old', () async {
    await installOfflinePack('on', packBytes('first'));
    await installOfflinePack('on', packBytes('second'));
    expect(await installedNote(), 'second');
  });

  test('an install leaves no staging directory behind', () async {
    await installOfflinePack('on', packBytes('first'));
    await installOfflinePack('on', packBytes('second'));
    final leftovers = await Directory(p.join(documents.path, 'offline_packs'))
        .list()
        .map((entry) => p.basename(entry.path))
        .toList();
    expect(leftovers, ['on']);
  });

  test('a file dropped from the new pack does not survive in the install',
      () async {
    await installOfflinePack('on', packBytes('first'));
    final stray = File(
      p.join(documents.path, 'offline_packs', 'on', 'overlays', 'stray.geojson'),
    );
    await stray.writeAsString('{}');
    await installOfflinePack('on', packBytes('second'));
    expect(await stray.exists(), isFalse);
  });
}
