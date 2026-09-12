import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/settings/visibility_settings.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:open_woods_map/waypoints/waypoints_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  WaypointIcon icon = WaypointIcon.pin,
  List<String> tags = const [],
}) => Waypoint(
  id: id,
  name: name,
  latitude: 45.5,
  longitude: -77.5,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  icon: icon,
  tags: tags,
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('owm-waypoints-page');
    PathProviderPlatform.instance = _Documents(root.path);
    SharedPreferences.setMockInitialValues({});
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
    WaypointStore store, {
    VisibilitySettings? visibility,
  }) async {
    final vis = visibility ?? VisibilitySettings();
    final popped = <WaypointsRequest?>[];
    // The filter chips scroll sideways and a grouped list repeats a waypoint
    // under each of its tags, so the default 800x600 surface leaves chips and
    // rows out of reach of a tap. Size the surface to the page rather than
    // scrolling to something in every test.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
                      visibility: vis,
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

  Future<WaypointStore> stockedWith(
    WidgetTester tester,
    List<Waypoint> waypoints,
  ) async {
    final store = WaypointStore();
    await tester.runAsync(() async {
      await store.load();
      await store.replaceAll(waypoints);
    });
    return store;
  }

  group('getting from the list to the map', () {
    // The list was previously a dead end: it showed coordinates with no way to
    // see where they were. The page does not own the camera, so both
    // affordances hand the waypoint back to the map shell instead of moving it.
    testWidgets('tapping the row hands the waypoint back', (tester) async {
      final store = await stockedWith(tester, [
        point('1', 'Bonnechere stand'),
      ]);

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
      final store = await stockedWith(tester, [
        point('1', 'Bonnechere stand'),
      ]);

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
      icon: WaypointIcon.trail,
      track: const [
        TrackPoint(latitude: 45, longitude: -77),
        TrackPoint(latitude: 45.01, longitude: -77),
      ],
    );

    testWidgets('a waypoint is offered no way to be followed', (tester) async {
      // There is no line to walk, and an option that could only ever fail is
      // worse than no option.
      final store = await stockedWith(tester, [
        point('1', 'Bonnechere stand'),
      ]);

      await pumpPage(tester, store);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);

      expect(find.text('Follow'), findsNothing);
      expect(find.text('Follow in reverse'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('a track asks the map to follow it forwards', (tester) async {
      final store = await stockedWith(tester, [walkedTrack('t1', 'Ridge loop')]);

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
      final store = await stockedWith(tester, [walkedTrack('t1', 'Ridge loop')]);

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
      final store = await stockedWith(tester, [walkedTrack('t1', 'Ridge loop')]);

      await pumpPage(tester, store);

      expect(find.textContaining('1.1 km'), findsOneWidget);
      expect(find.textContaining('track point'), findsNothing);
    });
  });

  group('deleting one waypoint', () {
    testWidgets('offers an undo and puts the waypoint back where it was', (
      tester,
    ) async {
      final store = await stockedWith(tester, [
        point('1', 'First'),
        point('2', 'Middle'),
        point('3', 'Last'),
      ]);

      await pumpPage(tester, store);
      // By name rather than by position: the list is sorted for display, so the
      // second row on screen is not the second waypoint in the store. Delete
      // also sits behind an overflow menu, so the menu has to be opened first.
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

  group('the grouped view', () {
    Future<WaypointStore> stocked(WidgetTester tester) => stockedWith(tester, [
      point('1', 'North stand', tags: ['ridge', 'opening day']),
      point('2', 'South stand', tags: ['ridge']),
      point('3', 'Spring', tags: ['creek']),
      point('4', 'Truck', tags: const []),
    ]);

    testWidgets('has a section for every tag in use', (tester) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('ridge · 2'), findsOneWidget);
      expect(find.text('creek · 1'), findsOneWidget);
      expect(find.text('opening day · 1'), findsOneWidget);
    });

    // Intended, not a bug. It is how labels work, and it is the reason the
    // total has to be stated separately from the section counts.
    testWidgets('a waypoint with two tags appears under both', (tester) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('North stand'), findsNWidgets(2));
    });

    // The single biggest trap in the design. Without this section a waypoint
    // with no tags is in the store, counted in the total, and nowhere on screen.
    testWidgets('an untagged waypoint has a section of its own', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('Untagged · 1'), findsOneWidget);
      expect(find.text('Truck'), findsOneWidget);
    });

    testWidgets('and that section is last', (tester) async {
      await pumpPage(tester, await stocked(tester));

      final untagged = tester.getTopLeft(find.text('Untagged · 1')).dy;
      for (final tag in ['creek · 1', 'opening day · 1', 'ridge · 2']) {
        expect(
          tester.getTopLeft(find.text(tag)).dy,
          lessThan(untagged),
          reason: '$tag should come before Untagged',
        );
      }
    });

    testWidgets('the untagged section is absent when nothing is untagged', (
      tester,
    ) async {
      final store = await stockedWith(tester, [
        point('1', 'North stand', tags: ['ridge']),
      ]);
      await pumpPage(tester, store);

      expect(find.textContaining('Untagged'), findsNothing);
    });

    // The sections deliberately add up to more than the list holds, so the
    // true total has to be said somewhere unambiguous.
    testWidgets('the total is stated, and the repetition explained', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.textContaining('4 waypoints'), findsOneWidget);
      expect(
        find.textContaining('5 rows below'),
        findsOneWidget,
        reason: 'four waypoints, five rows: one carries two tags',
      );
    });

    testWidgets('and no repetition is claimed when there is none', (
      tester,
    ) async {
      final store = await stockedWith(tester, [
        point('1', 'North stand', tags: ['ridge']),
        point('2', 'Truck'),
      ]);
      await pumpPage(tester, store);

      expect(find.text('2 waypoints'), findsOneWidget);
      expect(find.textContaining('rows below'), findsNothing);
    });

    testWidgets('one waypoint is one waypoint, not 1 waypoints', (
      tester,
    ) async {
      final store = await stockedWith(tester, [point('1', 'Truck')]);
      await pumpPage(tester, store);

      expect(find.text('1 waypoint'), findsOneWidget);
    });
  });

  group('filtering by tag', () {
    Future<WaypointStore> stocked(WidgetTester tester) => stockedWith(tester, [
      point('1', 'North stand', tags: ['ridge', 'opening day']),
      point('2', 'South stand', tags: ['ridge']),
      point('3', 'Spring', tags: ['creek']),
    ]);

    testWidgets('the chip row shows only tags that have waypoints', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('ridge 2'), findsOneWidget);
      expect(find.text('creek 1'), findsOneWidget);
      expect(find.text('All 3'), findsOneWidget);
    });

    testWidgets('picking a tag hides everything else', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('creek 1'));
      await settle(tester);

      expect(find.text('Spring'), findsOneWidget);
      expect(find.text('North stand'), findsNothing);
      expect(find.text('1 of 3 waypoints shown'), findsOneWidget);
    });

    // One tag was never how anyone describes what they are looking for.
    testWidgets('more than one tag can be selected at once', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('creek 1'));
      await settle(tester);
      await tester.tap(find.text('opening day 1'));
      await settle(tester);

      // Any, which is the default: the creek spot and the one tagged for
      // opening day, but not the stand that is only on the ridge.
      expect(find.text('Spring'), findsOneWidget);
      expect(find.text('South stand'), findsNothing);
      expect(find.text('North stand'), findsOneWidget);
    });

    // Asking for two tags gets two sections. Not three: the ridge was not
    // asked for, so the ridge is not a section, even though North stand is on
    // it. Sections under a filter are the tags that were picked.
    testWidgets('the sections are the tags that were picked', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('creek 1'));
      await settle(tester);
      await tester.tap(find.text('opening day 1'));
      await settle(tester);

      expect(find.text('creek · 1'), findsOneWidget);
      expect(find.text('opening day · 1'), findsOneWidget);
      expect(find.text('ridge · 1'), findsNothing);
    });

    // The complaint this rule answers: the chip said one number and the
    // section beside it said another.
    testWidgets('a chip and its section agree on the count', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('ridge 2'));
      await settle(tester);

      expect(find.text('ridge 2'), findsOneWidget);
      expect(find.text('ridge · 2'), findsOneWidget);
      expect(find.text('opening day · 1'), findsNothing);
    });

    // Whichever rule is in force, the chip says so. A filter whose rule is
    // invisible until it bites is worse than a chip stating the obvious.
    testWidgets('the matching rule is on screen and switchable', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      expect(find.text('Any of these tags'), findsOneWidget);

      await tester.tap(find.text('ridge 2'));
      await settle(tester);
      await tester.tap(find.text('opening day 1'));
      await settle(tester);
      // Once under each picked tag it carries, which for North stand is both.
      expect(find.text('North stand'), findsNWidgets(2));
      expect(find.text('South stand'), findsOneWidget);

      await tester.tap(find.text('Any of these tags'));
      await settle(tester);

      expect(find.text('All of these tags'), findsOneWidget);
      // Only the one carrying both. It is still under both picked tags, which
      // under "all of these" means the two sections hold the same waypoints —
      // the direct consequence of asking for waypoints that are in both.
      expect(find.text('North stand'), findsNWidgets(2));
      expect(find.text('South stand'), findsNothing);
    });

    testWidgets('All puts everything back', (tester) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.text('creek 1'));
      await settle(tester);
      await tester.tap(find.text('All 3'));
      await settle(tester);

      expect(find.text('Spring'), findsOneWidget);
      expect(find.text('South stand'), findsOneWidget);
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
      await tester.tap(find.text('ridge 2'));
      await settle(tester);
      await tester.tap(find.byTooltip('Export'));
      await settle(tester);
      expect(find.text('Exports the 2 shown'), findsOneWidget);
    });

    // A waypoint in two sections is still one waypoint to export.
    testWidgets('an export of a repeated waypoint counts it once', (
      tester,
    ) async {
      await pumpPage(tester, await stocked(tester));

      await tester.tap(find.byTooltip('Export'));
      await settle(tester);
      expect(find.text('Exports all 3'), findsOneWidget);
    });
  });

  group('what a section header can do', () {
    Future<WaypointStore> stocked(WidgetTester tester) => stockedWith(tester, [
      point('1', 'North stand', tags: ['ridge', 'opening day']),
      point('2', 'South stand', tags: ['ridge']),
      point('3', 'Spring', tags: ['creek']),
    ]);

    Future<void> openMenu(WidgetTester tester, String tag) async {
      await tester.tap(find.byTooltip('Actions for $tag'));
      await settle(tester);
    }

    // The old wording was a single "Delete all {label}", which was unambiguous
    // only while a waypoint could be in one group. These two have to be
    // impossible to confuse, because one is reversible bookkeeping and the
    // other destroys a season's work.
    testWidgets('offers two differently worded actions', (tester) async {
      await pumpPage(tester, await stocked(tester));
      await openMenu(tester, 'ridge');

      expect(
        find.text('Remove "ridge" from these 2, keep them'),
        findsOneWidget,
      );
      expect(find.text('Delete these 2 waypoints'), findsOneWidget);
      expect(find.textContaining('Delete all'), findsNothing);
    });

    testWidgets('removing the tag keeps every waypoint', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);
      await openMenu(tester, 'ridge');

      await tester.tap(find.text('Remove "ridge" from these 2, keep them'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove the tag'));
      await settle(tester);

      expect(store.items, hasLength(3));
      expect(store.items[0].tags, ['opening day']);
      expect(store.items[1].tags, isEmpty);
      expect(find.textContaining('Nothing was deleted'), findsOneWidget);
      // The one left with no tags at all has to still be on screen.
      expect(find.text('Untagged · 1'), findsOneWidget);
      expect(find.text('South stand'), findsOneWidget);
    });

    testWidgets('and can be undone', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);
      await openMenu(tester, 'ridge');

      await tester.tap(find.text('Remove "ridge" from these 2, keep them'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove the tag'));
      await settle(tester);
      await tester.tap(find.text('UNDO'));
      await settle(tester);

      expect(store.items[0].tags, ['ridge', 'opening day']);
      expect(store.items[1].tags, ['ridge']);
    });

    testWidgets('deleting removes the waypoints themselves', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);
      await openMenu(tester, 'ridge');

      await tester.tap(find.text('Delete these 2 waypoints'));
      await settle(tester);
      expect(
        find.text('Delete 2 waypoints tagged "ridge"?'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete them'));
      await settle(tester);

      expect(store.items.map((item) => item.name), ['Spring']);
      // Including out of the other section it was in, which the dialog said.
      expect(find.textContaining('opening day'), findsNothing);
    });

    // A confirmation is something people dismiss on reflex, so the undo has to
    // be there as well — and it has to restore the original order, not append.
    testWidgets('a delete can be undone in the order it was in', (
      tester,
    ) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);
      await openMenu(tester, 'ridge');

      await tester.tap(find.text('Delete these 2 waypoints'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete them'));
      await settle(tester);
      await tester.tap(find.text('UNDO'));
      await settle(tester);

      expect(store.items.map((item) => item.name), [
        'North stand',
        'South stand',
        'Spring',
      ]);
    });

    testWidgets('cancelling either one changes nothing', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await openMenu(tester, 'ridge');
      await tester.tap(find.text('Delete these 2 waypoints'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(store.items, hasLength(3));

      await openMenu(tester, 'ridge');
      await tester.tap(find.text('Remove "ridge" from these 2, keep them'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(store.items[0].tags, ['ridge', 'opening day']);
    });

    // Otherwise the list is left filtered to a tag that no longer exists,
    // showing "nothing matches this filter" over a list that has waypoints.
    testWidgets('a filter on a tag that is gone is cleared', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.text('creek 1'));
      await settle(tester);
      await openMenu(tester, 'creek');
      await tester.tap(find.text('Delete these 1 waypoint'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete them'));
      await settle(tester);

      expect(find.text('Nothing matches this filter.'), findsNothing);
      expect(find.text('North stand'), findsNWidgets(2));
    });

    // The menu says "these N", and with a filter on N can be fewer than carry
    // the tag. Acting on more than the number in the menu is the kind of
    // surprise that costs a season's work, so the sweep is scoped to what the
    // section shows and the dialog says what it is leaving behind.
    testWidgets('a bulk action touches only what the section shows', (
      tester,
    ) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.text('ridge 2'));
      await settle(tester);
      await tester.tap(find.text('opening day 1'));
      await settle(tester);
      await tester.tap(find.text('Any of these tags'));
      await settle(tester);

      // Only North stand carries both, so the ridge section holds one of the
      // two waypoints the ridge chip counts.
      await openMenu(tester, 'ridge');
      expect(find.text('Delete these 1 waypoint'), findsOneWidget);
      await tester.tap(find.text('Delete these 1 waypoint'));
      await settle(tester);
      expect(find.textContaining('hidden by the filter'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete them'));
      await settle(tester);

      expect(store.items.map((item) => item.name), ['South stand', 'Spring']);
    });

    testWidgets('and the same is true of removing the tag', (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store);

      await tester.tap(find.text('ridge 2'));
      await settle(tester);
      await tester.tap(find.text('opening day 1'));
      await settle(tester);
      await tester.tap(find.text('Any of these tags'));
      await settle(tester);

      await openMenu(tester, 'ridge');
      await tester.tap(find.text('Remove "ridge" from these 1, keep them'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove the tag'));
      await settle(tester);

      expect(store.items[0].tags, ['opening day']);
      // The one the filter was hiding keeps the tag it was never shown under.
      expect(store.items[1].tags, ['ridge']);
    });

    // There is no tag to take off an untagged waypoint, and "delete everything
    // with no tags" would put the most destructive sweep on the list's least
    // considered group.
    testWidgets('the untagged section offers no bulk action', (tester) async {
      final store = await stockedWith(tester, [point('1', 'Truck')]);
      await pumpPage(tester, store);

      expect(find.text('Untagged · 1'), findsOneWidget);
      expect(find.byTooltip('Actions for Untagged'), findsNothing);
      // The row still deletes, one waypoint at a time, with its undo.
      expect(find.byTooltip('More'), findsOneWidget);
    });
  });

  group('tag styling', () {
    // The rule that must not break: a tag's styling describes the tag. A
    // waypoint can carry several tags, so nothing about the waypoint's own
    // drawing may come from one of them.
    testWidgets('styling a tag leaves the waypoint\'s own icon alone', (
      tester,
    ) async {
      final store = await stockedWith(tester, [
        point('1', 'North stand', icon: WaypointIcon.stand, tags: ['ridge']),
      ]);
      await pumpPage(tester, store);

      await tester.tap(find.byTooltip('Actions for ridge'));
      await settle(tester);
      await tester.tap(find.text('Style this tag…'));
      await settle(tester);
      await tester.tap(find.byTooltip('Viewpoint'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await settle(tester);

      // The row keeps the glyph the waypoint was saved with.
      final row = tester.widget<Icon>(
        find.descendant(
          of: find.widgetWithText(ListTile, 'North stand'),
          matching: find.byType(Icon),
        ).first,
      );
      expect(row.icon, WaypointIcon.stand.icon);
      // And the waypoint itself is untouched on disk.
      expect(store.items.single.icon, WaypointIcon.stand);
    });

    testWidgets('the dialog says what the styling does not do', (tester) async {
      final store = await stockedWith(tester, [
        point('1', 'North stand', tags: ['ridge']),
      ]);
      await pumpPage(tester, store);

      await tester.tap(find.byTooltip('Actions for ridge'));
      await settle(tester);
      await tester.tap(find.text('Style this tag…'));
      await settle(tester);

      expect(
        find.textContaining('does not change how the waypoints themselves'),
        findsOneWidget,
      );
    });
  });

  group('hiding from the map', () {
    Future<WaypointStore> stocked(WidgetTester tester) => stockedWith(tester, [
      point('1', 'North stand', tags: ['ridge', 'opening day']),
      point('2', 'South stand', tags: ['ridge']),
      point('3', 'Spring', tags: ['creek']),
      point('4', 'Truck', tags: const []),
    ]);

    testWidgets('a hidden item is still in the list', (tester) async {
      final vis = VisibilitySettings();
      await vis.setItemHidden('1', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      expect(find.text('North stand'), findsNWidgets(2));
    });

    testWidgets('the export menu counts a hidden item', (tester) async {
      final vis = VisibilitySettings();
      await vis.setItemHidden('1', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      await tester.tap(find.byTooltip('Export'));
      await settle(tester);
      expect(find.text('Exports all 4'), findsOneWidget);
    });

    testWidgets('hiding a tag hides every item under it', (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      // The section header's eye shows the hidden state.
      expect(find.byTooltip('Show "ridge" on map'), findsOneWidget);
    });

    testWidgets('a tag-hidden item says so on its row', (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      expect(
        find.textContaining('#ridge (hidden)'),
        findsAtLeast(1),
      );
    });

    // Told apart by shape, not by tint. The two hidden states first differed
    // only by colour, and on this theme that was rgb(61,99,115) against
    // rgb(64,73,67) — measured off a phone screen, and no difference at arm's
    // length in sunlight, which is where this app gets used.
    testWidgets('the two hidden states are different glyphs', (tester) async {
      final byTag = VisibilitySettings();
      await byTag.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: byTag);

      // Scoped to the row, because the section header's own eye is legitimately
      // a slashed eye: the tag really is hidden and that is what the user just
      // did there.
      // Rows, plural: a waypoint appears under every tag it carries, and North
      // stand carries two.
      final row = find.widgetWithText(ListTile, 'North stand');
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.label_off)),
        findsWidgets,
      );
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.visibility_off)),
        findsNothing,
      );
    });

    // The central trap: an item hidden only by a tag must not have a "shown"
    // eye that appears to do nothing, and tapping it must do something useful.
    testWidgets('tapping the eye on a tag-hidden item offers to unhide the tag',
        (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      // The eye tooltip on a tag-hidden item names the responsible tag.
      await tester.tap(find.byTooltip('Hidden by #ridge').first);
      await settle(tester);

      expect(
        find.textContaining('hidden'),
        findsAtLeast(1),
      );
      expect(find.text('UNHIDE TAG'), findsOneWidget);
    });

    testWidgets('the unhide-tag action works from the row', (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      await tester.tap(find.byTooltip('Hidden by #ridge').first);
      await settle(tester);
      await tester.tap(find.text('UNHIDE TAG'));
      await settle(tester);

      expect(vis.isTagHidden('ridge'), isFalse);
    });

    testWidgets('toggling a tag eye hides and shows it', (tester) async {
      final vis = VisibilitySettings();
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      // Initially all tags are visible.
      expect(find.byTooltip('Hide "ridge" from map'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide "ridge" from map'));
      await settle(tester);

      expect(vis.isTagHidden('ridge'), isTrue);
      expect(find.byTooltip('Show "ridge" on map'), findsOneWidget);

      await tester.tap(find.byTooltip('Show "ridge" on map'));
      await settle(tester);

      expect(vis.isTagHidden('ridge'), isFalse);
    });

    testWidgets('toggling an item eye hides and shows it', (tester) async {
      final vis = VisibilitySettings();
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      await tester.tap(find.byTooltip('Hide from map').first);
      await settle(tester);

      expect(vis.hiddenItemIds, isNotEmpty);

      await tester.tap(find.byTooltip('Draw on map again').first);
      await settle(tester);

      expect(vis.hiddenItemIds, isEmpty);
    });

    // The eye sits next to a button that flies the camera to the waypoint, and
    // for a while both were labelled "Show on map". One label on two adjacent
    // controls that do different things is a bug in the row, not in the test.
    testWidgets('the eye and the camera button are not both called the same',
        (tester) async {
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: VisibilitySettings());

      expect(find.byTooltip('Show on map'), findsWidgets);
      expect(find.byTooltip('Hide from map'), findsWidgets);
      await tester.tap(find.byTooltip('Hide from map').first);
      await settle(tester);

      expect(find.byTooltip('Draw on map again'), findsOneWidget);
    });

    testWidgets('an item with one hidden and one shown tag is hidden',
        (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('ridge', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      // North stand carries [ridge, opening day]. Ridge is hidden, so the
      // row must show the tag-hidden indicator.
      expect(
        find.textContaining('#ridge (hidden)'),
        findsAtLeast(1),
      );
      // Spring (creek only) is not affected.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Spring'),
          matching: find.textContaining('Hidden on map'),
        ),
        findsNothing,
      );
    });

    testWidgets('hiding a tag no waypoint carries does nothing visible',
        (tester) async {
      final vis = VisibilitySettings();
      await vis.setTagHidden('nonexistent', hidden: true);
      final store = await stocked(tester);
      await pumpPage(tester, store, visibility: vis);

      expect(find.textContaining('Hidden on map'), findsNothing);
      expect(find.textContaining('4 waypoints'), findsOneWidget);
    });

    // The untagged section has no tag to hide, so no eye on its header.
    testWidgets('the untagged section has no visibility toggle', (
      tester,
    ) async {
      final store = await stockedWith(tester, [point('1', 'Truck')]);
      await pumpPage(tester, store);

      expect(find.text('Untagged · 1'), findsOneWidget);
      expect(find.byTooltip('Hide "Untagged" from map'), findsNothing);
    });
  });
}
