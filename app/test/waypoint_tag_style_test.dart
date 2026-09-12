import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/tag_style.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  late Directory root;
  late File file;
  late File waypoints;

  setUp(() {
    root = Directory.systemTemp.createTempSync('owm-tag-styles');
    file = File(p.join(root.path, 'open_woods_map_tag_styles.json'));
    waypoints = File(p.join(root.path, 'open_woods_map_waypoints.json'));
    PathProviderPlatform.instance = _Documents(root.path);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the OS to reap with the rest of the temp directory.
    }
  });

  group('what a tag with no styling is', () {
    test('an empty style, not a null one', () async {
      final store = TagStyleStore();
      await store.load();

      final style = store.styleFor('ridge');
      expect(style.isEmpty, isTrue);
      expect(style.icon, isNull);
      expect(style.colour, isNull);
    });

    // Typing a tag has to create it instantly with no styling and no dialog.
    // Nothing here is consulted to make a tag exist, and a tag with no entry in
    // the file is the normal case rather than a missing one.
    test('a missing file is no styling, not an error', () async {
      final store = TagStyleStore();
      await store.load();
      expect(store.styles, isEmpty);
    });
  });

  group('what reaches disk', () {
    test('its own file, beside the waypoints, not inside them', () async {
      final store = TagStyleStore();
      await store.load();
      await store.setStyle(
        'ridge',
        const TagStyle(
          icon: WaypointIcon.viewpoint,
          colour: WaypointColour.purple,
        ),
      );

      expect(file.existsSync(), isTrue);
      // The waypoints file's top-level JSON is a bare array, which is the whole
      // reason this is a second file: there is nowhere in an array to put a
      // per-tag anything.
      expect(waypoints.existsSync(), isFalse);
    });

    test('a top-level object with a version, so it can grow', () async {
      final store = TagStyleStore();
      await store.load();
      await store.setStyle(
        'ridge',
        const TagStyle(colour: WaypointColour.teal),
      );

      final written = jsonDecode(file.readAsStringSync());
      expect(written, isA<Map<String, dynamic>>());
      expect((written as Map)['version'], 1);
      expect(written['tags'], {
        'ridge': {'colour': 'teal'},
      });
    });

    test('round trips an icon and a colour', () async {
      final store = TagStyleStore();
      await store.load();
      await store.setStyle(
        'creek',
        const TagStyle(
          icon: WaypointIcon.fishing,
          colour: WaypointColour.blue,
        ),
      );

      final reloaded = TagStyleStore();
      await reloaded.load();
      expect(reloaded.styleFor('creek').icon, WaypointIcon.fishing);
      expect(reloaded.styleFor('creek').colour, WaypointColour.blue);
    });

    test('an icon alone or a colour alone is written alone', () async {
      final store = TagStyleStore();
      await store.load();
      await store.setStyle('a', const TagStyle(icon: WaypointIcon.tent));
      await store.setStyle('b', const TagStyle(colour: WaypointColour.black));

      final tags =
          (jsonDecode(file.readAsStringSync()) as Map)['tags'] as Map;
      expect(tags['a'], {'icon': 'tent'});
      expect(tags['b'], {'colour': 'black'});
    });

    // A tag whose styling was cleared is a tag with no styling, which is
    // absence. An entry left behind as `{}` would keep growing the file with a
    // record of choices that were undone.
    test('clearing a style removes the entry', () async {
      final store = TagStyleStore();
      await store.load();
      await store.setStyle('a', const TagStyle(icon: WaypointIcon.tent));
      await store.setStyle('a', const TagStyle());

      expect(store.styles, isEmpty);
      expect((jsonDecode(file.readAsStringSync()) as Map)['tags'], isEmpty);
    });
  });

  group('reading a file this build did not write', () {
    test('an icon id it does not know falls back rather than throwing',
        () async {
      file.writeAsStringSync(
        jsonEncode({
          'version': 99,
          'tags': {
            'ridge': {'icon': 'mineral-lick', 'colour': 'chartreuse'},
          },
        }),
      );

      final store = TagStyleStore();
      await store.load();
      expect(store.styleFor('ridge').icon, WaypointIcon.pin);
      expect(store.styleFor('ridge').colour, isNull);
    });

    // Styling is decoration, so unlike the waypoints file this degrades to
    // nothing rather than being preserved. Said out loud here so that a later
    // change does not quietly make it throw during page load instead.
    test('an unparseable file degrades to no styling', () async {
      file.writeAsStringSync('{not json');

      final store = TagStyleStore();
      await store.load();
      expect(store.styles, isEmpty);
    });
  });
}
