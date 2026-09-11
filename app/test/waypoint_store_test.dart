import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The documents directory the store writes into, pointed at a temporary
/// directory so a test can read back what actually reached disk.
class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Waypoint point(String id, {String name = 'Stand', double lat = 45.5}) =>
    Waypoint(
      id: id,
      name: name,
      latitude: lat,
      longitude: -77.5,
      notes: '',
      createdAt: DateTime.utc(2026, 9, 10, 12),
    );

void main() {
  late Directory root;
  late File file;

  setUp(() {
    root = Directory.systemTemp.createTempSync('owm-waypoints');
    file = File(p.join(root.path, 'open_woods_map_waypoints.json'));
    PathProviderPlatform.instance = _Documents(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('what reaches disk', () {
    test('a missing file is an empty list, not an error', () async {
      expect(await WaypointStore().load(), isEmpty);
    });

    // The only copy of a user's waypoints is this file. It has no schema
    // version, so anything that changes the model has to keep reading what
    // earlier builds wrote, and this pins down what they wrote.
    test('a saved waypoint round-trips through the file', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(point('1', name: 'Bonnechere stand'));

      final written = jsonDecode(file.readAsStringSync()) as List;
      expect(written, hasLength(1));
      expect(written.single, {
        'id': '1',
        'name': 'Bonnechere stand',
        'lat': 45.5,
        'lng': -77.5,
        'notes': '',
        'createdAt': '2026-09-10T12:00:00.000Z',
        'category': 'other',
        'tags': <String>[],
        // No 'colour' key: this waypoint follows its category, and writing the
        // resolved colour here would make that indistinguishable from a colour
        // the user picked.
        'track': <Object>[],
      });

      final reloaded = await WaypointStore().load();
      expect(reloaded.single.name, 'Bonnechere stand');
      expect(reloaded.single.track, isEmpty);
    });

    test('a track keeps its points and its order', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(
        Waypoint(
          id: 't1',
          name: 'Morning walk',
          latitude: 45.1,
          longitude: -77.1,
          notes: '',
          createdAt: DateTime.utc(2026, 9, 10),
          track: const [
            TrackPoint(latitude: 45.1, longitude: -77.1),
            TrackPoint(latitude: 45.2, longitude: -77.2),
            TrackPoint(latitude: 45.3, longitude: -77.3),
          ],
        ),
      );

      final track = (await WaypointStore().load()).single.track;
      expect(track.map((p) => p.latitude), [45.1, 45.2, 45.3]);
    });

    group('a track\'s look', () {
      Waypoint line(
        String id, {
        TrackStroke stroke = TrackStroke.solid,
        TrackMarker marker = TrackMarker.arrow,
      }) => Waypoint(
        id: id,
        name: 'Ridge',
        latitude: 45.1,
        longitude: -77.1,
        notes: '',
        createdAt: DateTime.utc(2026, 9, 10),
        stroke: stroke,
        marker: marker,
        track: const [
          TrackPoint(latitude: 45.1, longitude: -77.1),
          TrackPoint(latitude: 45.2, longitude: -77.2),
        ],
      );

      Future<Map<String, dynamic>> writeAndRead(Waypoint waypoint) async {
        final store = WaypointStore();
        await store.load();
        await store.add(waypoint);
        return (jsonDecode(file.readAsStringSync()) as List).single
            as Map<String, dynamic>;
      }

      test('is written when it is not the default', () async {
        final written = await writeAndRead(
          line(
            't1',
            stroke: TrackStroke.dotted,
            marker: TrackMarker.doubleChevron,
          ),
        );
        expect(written['stroke'], 'dotted');
        expect(written['marker'], 'double');

        final reloaded = (await WaypointStore().load()).single;
        expect(reloaded.stroke, TrackStroke.dotted);
        expect(reloaded.marker, TrackMarker.doubleChevron);
      });

      // A file of several hundred points has no business carrying "solid" on
      // every one of them.
      test('is left out entirely when it is the default', () async {
        final written = await writeAndRead(line('t1'));
        expect(written.containsKey('stroke'), isFalse);
        expect(written.containsKey('marker'), isFalse);
      });

      test('is never written for a point, which has no line', () async {
        final written = await writeAndRead(point('1'));
        expect(written.containsKey('stroke'), isFalse);
        expect(written.containsKey('marker'), isFalse);
      });

      // Every track saved before the look was choosable was drawn solid with
      // arrows, so that is what absence has to mean.
      test('absent reads back as solid with arrows', () async {
        file.writeAsStringSync(
          jsonEncode([
            {
              'id': 't1',
              'name': 'Old track',
              'lat': 45.1,
              'lng': -77.1,
              'notes': '',
              'createdAt': '2026-01-01T00:00:00.000Z',
              'track': [
                {'lat': 45.1, 'lng': -77.1},
                {'lat': 45.2, 'lng': -77.2},
              ],
            },
          ]),
        );

        final loaded = (await WaypointStore().load()).single;
        expect(loaded.stroke, TrackStroke.solid);
        expect(loaded.marker, TrackMarker.arrow);
      });

      test('an unreadable value falls back rather than throwing', () async {
        file.writeAsStringSync(
          jsonEncode([
            {
              'id': 't1',
              'name': 'From the future',
              'lat': 45.1,
              'lng': -77.1,
              'notes': '',
              'createdAt': '2026-01-01T00:00:00.000Z',
              'stroke': 'zigzag',
              'marker': 'barbed',
              'track': [
                {'lat': 45.1, 'lng': -77.1},
                {'lat': 45.2, 'lng': -77.2},
              ],
            },
          ]),
        );

        final store = WaypointStore();
        final loaded = (await store.load()).single;
        expect(store.unreadableFilePath, isNull);
        expect(loaded.stroke, TrackStroke.solid);
        expect(loaded.marker, TrackMarker.arrow);
      });

      test('copyWith carries the look through an edit', () async {
        final edited = line('t1', stroke: TrackStroke.dashed)
            .copyWith(name: 'Renamed');
        expect(edited.stroke, TrackStroke.dashed);
        expect(edited.marker, TrackMarker.arrow);

        expect(
          edited.copyWith(marker: TrackMarker.none).marker,
          TrackMarker.none,
        );
        // Changing the marker must not quietly reset the stroke.
        expect(
          edited.copyWith(marker: TrackMarker.none).stroke,
          TrackStroke.dashed,
        );
      });
    });

    // The map shell loads waypoints during bootstrap, so a throw here used to
    // be a launch failure. Reporting empty is only safe because the file is
    // moved aside first; otherwise the next save writes over what was still
    // recoverable.
    test('a malformed file is reported, not thrown and not overwritten',
        () async {
      file.writeAsStringSync('{not json');

      final store = WaypointStore();
      expect(await store.load(), isEmpty);
      expect(store.unreadableFilePath, isNotNull);
      expect(File(store.unreadableFilePath!).readAsStringSync(), '{not json');
      expect(file.existsSync(), isFalse);

      await store.add(point('1'));
      expect(File(store.unreadableFilePath!).readAsStringSync(), '{not json');
      expect((await WaypointStore().load()), hasLength(1));
    });

    test('a clean load reports no unreadable file', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(point('1'));

      final reloaded = WaypointStore();
      await reloaded.load();
      expect(reloaded.unreadableFilePath, isNull);
    });

    test('a save leaves no staging file behind', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(point('1'));

      expect(
        root.listSync().map((entry) => p.basename(entry.path)),
        ['open_woods_map_waypoints.json'],
      );
    });
  });

  group('editing', () {
    test('delete removes only the named waypoint', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(point('1', name: 'A'));
      await store.add(point('2', name: 'B'));

      await store.delete('1');

      expect(store.items.map((item) => item.name), ['B']);
      expect((await WaypointStore().load()).map((item) => item.name), ['B']);
    });

    // Undo in the list re-saves the whole collection with the deleted waypoint
    // put back at its old index, so order has to survive a replace.
    test('replaceAll keeps the order it is given', () async {
      final store = WaypointStore();
      await store.load();
      await store.replaceAll([point('1', name: 'A'), point('3', name: 'C')]);

      await store.replaceAll([
        point('1', name: 'A'),
        point('2', name: 'B'),
        point('3', name: 'C'),
      ]);

      expect((await WaypointStore().load()).map((item) => item.name), [
        'A',
        'B',
        'C',
      ]);
    });

    test('update rewrites a waypoint in place', () async {
      final store = WaypointStore();
      await store.load();
      await store.add(point('1', name: 'Old'));

      await store.update(store.items.single.copyWith(name: 'New'));

      final reloaded = await WaypointStore().load();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.name, 'New');
    });
  });
}
