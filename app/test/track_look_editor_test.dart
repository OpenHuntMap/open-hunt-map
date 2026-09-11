import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_preview.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';
import 'package:open_woods_map/waypoints/waypoint_editor.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

Waypoint _point() => Waypoint(
  id: '1',
  name: 'Stand',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  category: WaypointCategory.stand,
);

Waypoint _track({
  TrackStroke stroke = TrackStroke.solid,
  TrackMarker marker = TrackMarker.arrow,
  WaypointColour? colour,
}) => Waypoint(
  id: 't1',
  name: 'Ridge loop',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  category: WaypointCategory.trail,
  colour: colour,
  stroke: stroke,
  marker: marker,
  track: const [
    TrackPoint(latitude: 45.1, longitude: -77.1),
    TrackPoint(latitude: 45.2, longitude: -77.2),
  ],
);

void main() {
  Future<List<Waypoint>> pumpEditor(
    WidgetTester tester,
    Waypoint existing,
  ) async {
    // Tall on purpose. The editor scrolls itself, and on a phone-sized surface
    // the Save button sits below the fold, where a tap silently misses.
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final saved = <Waypoint>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WaypointEditor(
            existing: existing,
            knownTags: const [],
            isNew: false,
            onSave: saved.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  group('where the look is offered', () {
    testWidgets('a track gets a line section with a preview', (tester) async {
      await pumpEditor(tester, _track());

      expect(find.text('LINE'), findsOneWidget);
      expect(find.text('DIRECTION'), findsOneWidget);
      expect(find.byType(TrackPreview), findsOneWidget);
      for (final stroke in TrackStroke.values) {
        expect(find.text(stroke.label), findsOneWidget);
      }
      for (final marker in TrackMarker.values) {
        expect(find.text(marker.label), findsOneWidget);
      }
    });

    // A point has no stroke to pattern and no direction to mark. Offering it
    // either would suggest otherwise.
    testWidgets('a point gets neither', (tester) async {
      await pumpEditor(tester, _point());

      expect(find.text('LINE'), findsNothing);
      expect(find.text('DIRECTION'), findsNothing);
      expect(find.byType(TrackPreview), findsNothing);
      expect(find.text('Dotted'), findsNothing);
    });
  });

  group('choosing a look', () {
    testWidgets('the saved track carries the stroke that was picked',
        (tester) async {
      final saved = await pumpEditor(tester, _track());

      await tester.tap(find.text('Dotted'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));

      expect(saved.single.stroke, TrackStroke.dotted);
      expect(saved.single.marker, TrackMarker.arrow);
    });

    testWidgets('the saved track carries the marker that was picked',
        (tester) async {
      final saved = await pumpEditor(tester, _track());

      await tester.tap(find.text('Double chevrons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));

      expect(saved.single.marker, TrackMarker.doubleChevron);
    });

    testWidgets('None is a reachable choice, not just the absence of one',
        (tester) async {
      final saved = await pumpEditor(
        tester,
        _track(marker: TrackMarker.doubleChevron),
      );

      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));

      expect(saved.single.marker, TrackMarker.none);
    });

    testWidgets('an existing look is what starts selected', (tester) async {
      await pumpEditor(
        tester,
        _track(stroke: TrackStroke.dashed, marker: TrackMarker.chevron),
      );

      ChoiceChip chip(String label) => tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip('Dashed').selected, isTrue);
      expect(chip('Solid').selected, isFalse);
      expect(chip('Chevrons').selected, isTrue);
      expect(chip('Arrows').selected, isFalse);
    });

    // Renaming a track must not silently restyle it.
    testWidgets('editing something else leaves the look alone', (tester) async {
      final saved = await pumpEditor(
        tester,
        _track(stroke: TrackStroke.dotted, marker: TrackMarker.none),
      );

      await tester.enterText(find.byType(TextField).first, 'Renamed');
      await tester.tap(find.text('Done'));

      expect(saved.single.name, 'Renamed');
      expect(saved.single.stroke, TrackStroke.dotted);
      expect(saved.single.marker, TrackMarker.none);
    });
  });

  group('the preview', () {
    // Null colour means "follow the category", and a preview that read the raw
    // field would draw every unoverridden track in the same default.
    testWidgets('resolves a category colour rather than showing a default',
        (tester) async {
      await pumpEditor(tester, _track());

      final preview = tester.widget<TrackPreview>(find.byType(TrackPreview));
      expect(preview.colour, WaypointCategory.trail.colour);
    });

    testWidgets('follows a colour override', (tester) async {
      await pumpEditor(tester, _track(colour: WaypointColour.red));

      final preview = tester.widget<TrackPreview>(find.byType(TrackPreview));
      expect(preview.colour, WaypointColour.red.value);
    });

    testWidgets('repaints as the choice changes', (tester) async {
      await pumpEditor(tester, _track());

      await tester.tap(find.text('Dashed'));
      await tester.pumpAndSettle();

      final preview = tester.widget<TrackPreview>(find.byType(TrackPreview));
      expect(preview.stroke, TrackStroke.dashed);
    });

    testWidgets('draws every combination without throwing', (tester) async {
      // Nine looks, and the painter does the dash arithmetic itself, so a
      // division by a zero-length pattern would only show up here.
      for (final stroke in TrackStroke.values) {
        for (final marker in TrackMarker.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TrackPreview(
                  colour: WaypointColour.white.value,
                  stroke: stroke,
                  marker: marker,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$stroke / $marker');
        }
      }
    });
  });
}
