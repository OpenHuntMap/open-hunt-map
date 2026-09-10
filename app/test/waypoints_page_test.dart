import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:open_woods_map/waypoints/waypoints_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Waypoint point(String id, String name) => Waypoint(
  id: id,
  name: name,
  latitude: 45.5,
  longitude: -77.5,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('owm-waypoints-page');
    PathProviderPlatform.instance = _Documents(root.path);
  });

  // Best effort: on Windows a write the store started but the test did not wait
  // for still holds the file, and failing the teardown would hide the result of
  // the test itself.
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the OS to reap with the rest of the temp directory.
    }
  });

  /// Advances past the route transition and the store's load.
  ///
  /// Two things here are not the obvious call. `runAsync`, because the store
  /// reads a real file and `testWidgets` runs its body against a fake clock
  /// that never lets real IO complete — without it the page waits on its own
  /// `initState` for ever. And repeated `pump` rather than `pumpAndSettle`,
  /// because the loading spinner schedules frames indefinitely, so settling
  /// waits out its ten-minute timeout instead of finishing.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Pushes the page the way the map shell does and reports what it popped, so
  /// a test can assert on the waypoint the map would have flown to.
  Future<Waypoint?> pumpPage(WidgetTester tester, WaypointStore store) async {
    Waypoint? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.push<Waypoint>(
                context,
                MaterialPageRoute(
                  builder: (_) => WaypointsPage(
                    store: store,
                    suggestedLocation: const LatLng(45, -77),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    return popped;
  }

  group('getting from the list to the map', () {
    // The list was previously a dead end: it showed coordinates with no way to
    // see where they were. The page does not own the camera, so both
    // affordances hand the waypoint back to the map shell instead of moving it.
    testWidgets('tapping the row hands the waypoint back', (tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(point('1', 'Bonnechere stand'));
      });

      await pumpPage(tester, store);
      expect(find.text('Bonnechere stand'), findsOneWidget);

      await tester.tap(find.text('Bonnechere stand'));
      await settle(tester);

      expect(find.byType(WaypointsPage), findsNothing);
    });

    testWidgets('so does the explicit button', (tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(point('1', 'Bonnechere stand'));
      });

      await pumpPage(tester, store);
      await tester.tap(find.byTooltip('Show on map'));
      await settle(tester);

      expect(find.byType(WaypointsPage), findsNothing);
    });
  });

  group('deleting', () {
    testWidgets('offers an undo and puts the waypoint back where it was', (
      tester,
    ) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.replaceAll([
          point('1', 'First'),
          point('2', 'Middle'),
          point('3', 'Last'),
        ]);
      });

      await pumpPage(tester, store);
      await tester.tap(find.byTooltip('Delete').at(1));
      await settle(tester);

      expect(store.items.map((item) => item.name), ['First', 'Last']);
      expect(find.text('Deleted Middle.'), findsOneWidget);

      await tester.tap(find.text('UNDO'));
      await settle(tester);

      // Back at index 1, not appended. A waypoint that reappears at the bottom
      // of a long list reads as a different waypoint.
      expect(store.items.map((item) => item.name), [
        'First',
        'Middle',
        'Last',
      ]);
    });
  });

  group('an unreadable file', () {
    // An empty list with no explanation reads as "you never saved anything",
    // which would invite the user to start adding points over a file that is
    // still sitting on disk.
    testWidgets('says so rather than looking like an empty list', (
      tester,
    ) async {
      File(
        '${root.path}${Platform.pathSeparator}open_woods_map_waypoints.json',
      ).writeAsStringSync('{not json');

      await pumpPage(tester, WaypointStore());

      expect(find.text('Your waypoint file could not be read'), findsOneWidget);
      expect(find.textContaining('.unreadable'), findsOneWidget);
    });
  });
}
