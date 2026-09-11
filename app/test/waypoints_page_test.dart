import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';
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

Waypoint point(
  String id,
  String name, {
  WaypointCategory category = WaypointCategory.other,
  List<String> tags = const [],
}) => Waypoint(
  id: id,
  name: name,
  latitude: 45.5,
  longitude: -77.5,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  category: category,
  tags: tags,
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

  /// Pushes the page the way the map shell does and collects what it pops.
  ///
  /// The list is returned rather than the request itself because the pop happens
  /// long after this returns: the caller taps something, then reads the list.
  Future<List<WaypointsRequest?>> pumpPage(
    WidgetTester tester,
    WaypointStore store,
  ) async {
    final popped = <WaypointsRequest?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped.add(
                await Navigator.push<WaypointsRequest>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WaypointsPage(
                      store: store,
                      suggestedLocation: const LatLng(45, -77),
                    ),
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

      final popped = await pumpPage(tester, store);
      expect(find.text('Bonnechere stand'), findsOneWidget);

      await tester.tap(find.text('Bonnechere stand'));
      await settle(tester);

      expect(find.byType(WaypointsPage), findsNothing);
      expect(popped.single, isA<RevealWaypoint>());
      expect(
        (popped.single! as RevealWaypoint).waypoint.name,
        'Bonnechere stand',
      );
    });

    testWidgets('so does the explicit button', (tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(point('1', 'Bonnechere stand'));
      });

      final popped = await pumpPage(tester, store);
      await tester.tap(find.byTooltip('Show on map'));
      await settle(tester);

      expect(find.byType(WaypointsPage), findsNothing);
      expect(popped.single, isA<RevealWaypoint>());
    });
  });

  group('following a track from the list', () {
    /// A two-point line, which is the least that can be followed.
    Waypoint walkedTrack(String id, String name) => Waypoint(
      id: id,
      name: name,
      latitude: 45,
      longitude: -77,
      notes: '',
      createdAt: DateTime.utc(2026, 9, 11),
      category: WaypointCategory.trail,
      track: const [
        TrackPoint(latitude: 45, longitude: -77),
        TrackPoint(latitude: 45.01, longitude: -77),
      ],
    );

    testWidgets('a waypoint is offered no way to be followed', (tester) async {
      // There is no line to walk, and an option that could only ever fail is
      // worse than no option.
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(point('1', 'Bonnechere stand'));
      });

      await pumpPage(tester, store);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);

      expect(find.text('Follow'), findsNothing);
      expect(find.text('Follow in reverse'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('a track asks the map to follow it forwards', (tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(walkedTrack('t1', 'Ridge loop'));
      });

      final popped = await pumpPage(tester, store);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);
      await tester.tap(find.text('Follow'));
      await settle(tester);

      expect(popped.single, isA<FollowTrack>());
      final request = popped.single! as FollowTrack;
      expect(request.track.name, 'Ridge loop');
      expect(request.reversed, isFalse);
    });

    testWidgets('and in reverse when that is what was picked', (tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(walkedTrack('t1', 'Ridge loop'));
      });

      final popped = await pumpPage(tester, store);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);
      await tester.tap(find.text('Follow in reverse'));
      await settle(tester);

      // The direction is decided here and carried, rather than the map being
      // asked to follow and then prompting for a direction it already knows.
      expect((popped.single! as FollowTrack).reversed, isTrue);
    });

    testWidgets('the row shows how far and how long, not a point count', (
      tester,
    ) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.add(walkedTrack('t1', 'Ridge loop'));
      });

      await pumpPage(tester, store);

      expect(find.textContaining('1.1 km'), findsOneWidget);
      expect(find.textContaining('track point'), findsNothing);
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
      // By name rather than by position: the list is now sorted by category and
      // then name for display, so the second row on screen is not the second
      // waypoint in the store. Delete also moved behind an overflow menu once
      // Edit joined it, so the menu has to be opened first.
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Middle'),
          matching: find.byTooltip('More'),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Delete').last);
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

  group('filtering', () {
    Future<WaypointStore> stocked(WidgetTester tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.replaceAll([
          point('1', 'North stand', category: WaypointCategory.stand),
          point('2', 'South stand', category: WaypointCategory.stand),
          point('3', 'Spring', category: WaypointCategory.water, tags: ['creek']),
        ]);
      });
      return store;
    }

    // Only categories in use, or the row opens with fifteen chips of which
    // twelve match nothing.
    testWidgets('the chip row shows only categories that have waypoints', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('Tree stand 2'), findsOneWidget);
      expect(find.text('Water source 1'), findsOneWidget);
      expect(find.textContaining('Trail camera'), findsNothing);
      expect(find.text('All 3'), findsOneWidget);
    });

    testWidgets('picking a category hides everything else', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('Water source 1'));
      await settle(tester);

      expect(find.text('Spring'), findsOneWidget);
      expect(find.text('North stand'), findsNothing);
    });

    testWidgets('a tag chip filters too', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('creek'));
      await settle(tester);

      expect(find.text('Spring'), findsOneWidget);
      expect(find.text('South stand'), findsNothing);
    });

    // The filter is the export selection, so the menu has to say what will
    // leave rather than leaving the user to guess.
    testWidgets('the export menu counts what is shown, not what is held', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.byTooltip('Export'));
      await settle(tester);
      expect(find.text('Exports all 3'), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await settle(tester);
      await tester.tap(find.text('Tree stand 2'));
      await settle(tester);
      await tester.tap(find.byTooltip('Export'));
      await settle(tester);
      expect(find.text('Exports the 2 shown'), findsOneWidget);
    });
  });

  group('deleting a whole category', () {
    Future<WaypointStore> stocked(WidgetTester tester) async {
      final store = WaypointStore();
      await tester.runAsync(() async {
        await store.load();
        await store.replaceAll([
          point('1', 'North stand', category: WaypointCategory.stand),
          point('2', 'Spring', category: WaypointCategory.water),
          point('3', 'South stand', category: WaypointCategory.stand),
        ]);
      });
      return store;
    }

    testWidgets('asks first, and keeping them changes nothing', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.byTooltip('Delete all Tree stand'));
      await settle(tester);
      expect(find.text('Delete 2 Tree stand waypoint(s)?'), findsOneWidget);

      await tester.tap(find.text('Keep them'));
      await settle(tester);
      expect(store.items, hasLength(3));
    });

    // A confirmation is something people dismiss on reflex, so the undo has to
    // be there as well — and it has to restore the original order, not append.
    testWidgets('confirming removes the category and undo restores order', (
      tester,
    ) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.byTooltip('Delete all Tree stand'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);

      expect(store.items.map((item) => item.name), ['Spring']);
      expect(find.text('Deleted 2 Tree stand.'), findsOneWidget);

      await tester.tap(find.text('UNDO'));
      await settle(tester);

      expect(store.items.map((item) => item.name), [
        'North stand',
        'Spring',
        'South stand',
      ]);
    });

    // Otherwise the list is left filtered to a category that no longer exists,
    // showing "nothing matches this filter" over a list that has waypoints.
    testWidgets('clears a filter that pointed at the deleted category', (
      tester,
    ) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.text('Tree stand 2'));
      await settle(tester);
      await tester.tap(find.byTooltip('Delete all Tree stand'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);

      expect(find.text('Nothing matches this filter.'), findsNothing);
      expect(find.text('Spring'), findsOneWidget);
    });
  });
}
