import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/legacy_categories.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// A waypoint as a build that still had categories wrote it.
Map<String, dynamic> stored(
  String category, {
  List<String> tags = const [],
  String id = '1',
}) => {
  'id': id,
  'name': 'Saved before icons',
  'lat': 45.5,
  'lng': -77.5,
  'notes': '',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'category': category,
  'tags': tags,
  'track': <Object>[],
};

void main() {
  // This is user data on real devices, and there is no schema version in the
  // file to tell us which shape we are looking at. Every one of these is a way
  // the migration could silently lose something the user put there.
  group('a stored category becomes an icon and a tag', () {
    test('the glyph it drew as is the glyph it keeps', () {
      expect(Waypoint.fromJson(stored('stand')).icon, WaypointIcon.stand);
      expect(Waypoint.fromJson(stored('portage')).icon, WaypointIcon.portage);
      expect(Waypoint.fromJson(stored('camera')).icon, WaypointIcon.camera);
    });

    // The label, not the id: "tree stand" is what the user saw and chose, and
    // "stand" is an internal string they have never been shown.
    test('its label becomes a tag', () {
      expect(Waypoint.fromJson(stored('stand')).tags, ['tree stand']);
      expect(Waypoint.fromJson(stored('boundary')).tags, ['boundary walked']);
      expect(Waypoint.fromJson(stored('parking')).tags, ['parking or access']);
    });

    test('tags the user already had are kept, with the label after them', () {
      expect(
        Waypoint.fromJson(stored('stand', tags: ['Ridge', 'north'])).tags,
        ['ridge', 'north', 'tree stand'],
      );
    });

    // "Other" was the absence of a choice. Carrying it forward would tag a
    // large part of an existing list with a word that classifies nothing, and a
    // tag every waypoint has cannot filter anything.
    test('"other" adds no tag and leaves the waypoint on the pin', () {
      final migrated = Waypoint.fromJson(stored('other'));
      expect(migrated.icon, WaypointIcon.pin);
      expect(migrated.tags, isEmpty);
    });

    test('a category this build never had adds no tag either', () {
      // It can only have come from a later build, so there is no label to use
      // and nothing honest to invent. The waypoint itself survives, which is
      // the part that matters.
      final migrated = Waypoint.fromJson(stored('mineral-lick'));
      expect(migrated.icon, WaypointIcon.pin);
      expect(migrated.tags, isEmpty);
      expect(migrated.name, 'Saved before icons');
    });

    test('a waypoint with no category and no icon is not corrupt', () {
      final json = stored('other')..remove('category');
      final loaded = Waypoint.fromJson(json);
      expect(loaded.icon, WaypointIcon.pin);
      expect(loaded.tags, isEmpty);
    });

    // Every one of the twenty has to land somewhere: a category with no mapping
    // would quietly turn into a pin with no tag, which is the whole of what the
    // user had said about that waypoint.
    test('all twenty old categories migrate to something', () {
      for (final entry in legacyCategoryLabels.entries) {
        final migrated = Waypoint.fromJson(stored(entry.key));
        if (entry.key == 'other') continue;
        expect(
          migrated.tags,
          [entry.value.toLowerCase()],
          reason: entry.key,
        );
        expect(
          migrated.icon,
          isNot(WaypointIcon.pin),
          reason: '${entry.key} lost its glyph',
        );
      }
    });

    // A newer field wins outright. Otherwise a waypoint edited after the
    // migration would pick its old category's tag back up on every load.
    test('a stored icon wins and no tag is added', () {
      final json = stored('stand')..['icon'] = 'fishing';
      final loaded = Waypoint.fromJson(json);
      expect(loaded.icon, WaypointIcon.fishing);
      expect(loaded.tags, isEmpty);
    });
  });

  group('through the store and back to disk', () {
    late Directory root;
    late File file;

    setUp(() {
      root = Directory.systemTemp.createTempSync('owm-migration');
      file = File(p.join(root.path, 'open_woods_map_waypoints.json'));
      PathProviderPlatform.instance = _Documents(root.path);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('an old file loads migrated, and nothing is lost', () async {
      file.writeAsStringSync(
        jsonEncode([
          stored('stand', id: 'a'),
          stored('water', tags: ['creek'], id: 'b'),
          stored('other', id: 'c'),
        ]),
      );

      final loaded = await WaypointStore().load();

      expect(loaded, hasLength(3));
      expect(loaded.map((item) => item.id), ['a', 'b', 'c']);
      expect(loaded[0].tags, ['tree stand']);
      expect(loaded[1].tags, ['creek', 'water source']);
      expect(loaded[2].tags, isEmpty);
    });

    // Loading must not write. A build that rewrote the file on load would have
    // one chance to corrupt it before the user had done anything at all, and
    // downgrading to the previous build would then find its categories gone.
    test('loading leaves the file exactly as it was', () async {
      final original = jsonEncode([stored('stand')]);
      file.writeAsStringSync(original);

      await WaypointStore().load();

      expect(file.readAsStringSync(), original);
    });

    test('the next save writes the migrated form', () async {
      file.writeAsStringSync(jsonEncode([stored('stand', id: 'a')]));
      final store = WaypointStore();
      await store.load();

      // Any save rewrites the whole array, so one unrelated edit migrates
      // everything in the file.
      await store.add(
        Waypoint(
          id: 'b',
          name: 'New one',
          latitude: 45,
          longitude: -77,
          notes: '',
          createdAt: DateTime.utc(2026, 9, 11),
        ),
      );

      final written = (jsonDecode(file.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      expect(written.first['icon'], 'stand');
      expect(written.first['tags'], ['tree stand']);
      expect(
        written.first.containsKey('category'),
        isFalse,
        reason: 'a category written back would be a classification we no '
            'longer have, and an older build would trust it',
      );
    });

    // The migration must not weaken this. An unreadable file is still moved
    // aside rather than reported as an empty list over the top of it.
    test('an unreadable file is still preserved, not migrated away', () async {
      file.writeAsStringSync('{not json');

      final store = WaypointStore();
      expect(await store.load(), isEmpty);
      expect(store.unreadableFilePath, isNotNull);
      expect(File(store.unreadableFilePath!).readAsStringSync(), '{not json');
    });
  });

  group('the twenty labels survive as suggestions', () {
    test('there are nineteen of them, and "other" is not one', () {
      expect(suggestedTags, hasLength(19));
      expect(suggestedTags, isNot(contains('other')));
      expect(suggestedTags, contains('tree stand'));
      expect(suggestedTags, contains('portage'));
    });

    // The suggestion and the tag a migrated waypoint carries have to be the
    // same string, or a device that migrated and a device that took the
    // suggestion end up with two tags that read identically.
    test('a suggestion is spelled exactly as the migration spells it', () {
      for (final entry in legacyCategoryLabels.entries) {
        if (entry.key == 'other') continue;
        expect(
          suggestedTags,
          contains(legacyCategoryTags(entry.key).single),
          reason: entry.key,
        );
      }
    });

    test('they are already normalised, so taking one changes nothing', () {
      expect(normaliseTags(suggestedTags), suggestedTags);
    });
  });

  group('recognising an old category by name', () {
    test('by id and by label, either case', () {
      expect(legacyCategoryId('stand'), 'stand');
      expect(legacyCategoryId('Tree stand'), 'stand');
      expect(legacyCategoryId('  BOUNDARY WALKED '), 'boundary');
    });

    test('anything else is not one', () {
      expect(legacyCategoryId('ridge'), isNull);
      expect(legacyCategoryId(''), isNull);
      expect(legacyCategoryId(null), isNull);
      // A label this build invented for a new glyph is not an old category.
      expect(legacyCategoryId('Tent'), isNull);
    });
  });
}
