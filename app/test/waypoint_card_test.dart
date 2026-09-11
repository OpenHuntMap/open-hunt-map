import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_preview.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_card.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

Waypoint _point({
  String notes = '',
  List<String> tags = const [],
}) => Waypoint(
  id: 'w1',
  name: 'Field edge stand',
  latitude: 45.12345678,
  longitude: -77.87654321,
  notes: notes,
  createdAt: DateTime.utc(2026, 9, 10),
  category: WaypointCategory.stand,
  tags: tags,
);

Waypoint _track() => Waypoint(
  id: 't1',
  name: 'Ridge loop',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  category: WaypointCategory.trail,
  stroke: TrackStroke.dotted,
  marker: TrackMarker.chevron,
  track: const [
    TrackPoint(latitude: 45.1, longitude: -77.1),
    TrackPoint(latitude: 45.11, longitude: -77.1),
  ],
);

void main() {
  /// Opens the card the way the map does, and reports what it asked for.
  ///
  /// The request is the whole contract with the map shell, so the tests assert on
  /// it rather than on which button was drawn: a button that pops the wrong
  /// request looks right on screen and does the wrong thing.
  Future<WaypointCardRequest?> open(
    WidgetTester tester,
    Waypoint waypoint, {
    String? tap,
  }) async {
    WaypointCardRequest? result;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showWaypointCard(ctx, waypoint).then((value) => result = value);
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
    }
    return result;
  }

  group('a waypoint tapped on the map', () {
    testWidgets('names itself and where it is', (tester) async {
      await open(tester, _point());
      expect(find.text('Field edge stand'), findsOneWidget);
      // Five places is about a metre, which is finer than any consumer fix and
      // coarse enough to read out loud over a radio.
      expect(find.text('Tree stand · 45.12346, -77.87654'), findsOneWidget);
    });

    testWidgets('offers editing and land info but not following',
        (tester) async {
      await open(tester, _point());
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Land info'), findsOneWidget);
      // A point is not a line. Nothing to walk along and nothing to reverse.
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Reverse'), findsNothing);
      expect(find.byType(TrackPreview), findsNothing);
    });

    testWidgets('shows notes and tags when there are any', (tester) async {
      await open(tester, _point(notes: 'Wind out of the west', tags: ['fall']));
      expect(find.text('Wind out of the west'), findsOneWidget);
      expect(find.text('#fall'), findsOneWidget);
    });

    testWidgets('asks to edit the waypoint that was tapped', (tester) async {
      final waypoint = _point();
      final request = await open(tester, waypoint, tap: 'Edit');
      expect(request, isA<EditFromCard>());
      expect((request! as EditFromCard).waypoint.id, waypoint.id);
    });

    testWidgets('asks for land info at the tapped spot', (tester) async {
      expect(
        await open(tester, _point(), tap: 'Land info'),
        isA<LandInfoFromCard>(),
      );
    });
  });

  group('a track tapped on the map', () {
    testWidgets('describes the walk rather than a single coordinate',
        (tester) async {
      await open(tester, _track());
      expect(find.text('Ridge loop'), findsOneWidget);
      expect(find.textContaining('Trail · '), findsOneWidget);
      expect(find.textContaining('45.1,'), findsNothing);
    });

    testWidgets('shows the look the tapped line is drawn in', (tester) async {
      await open(tester, _track());
      final preview = tester.widget<TrackPreview>(find.byType(TrackPreview));
      expect(preview.stroke, TrackStroke.dotted);
      expect(preview.marker, TrackMarker.chevron);
    });

    testWidgets('follows forward', (tester) async {
      final request = await open(tester, _track(), tap: 'Follow');
      expect(request, isA<FollowFromCard>());
      expect((request! as FollowFromCard).reversed, isFalse);
      expect((request as FollowFromCard).track.id, 't1');
    });

    testWidgets('follows in reverse', (tester) async {
      final request = await open(tester, _track(), tap: 'Reverse');
      expect(request, isA<FollowFromCard>());
      expect((request! as FollowFromCard).reversed, isTrue);
    });

    testWidgets('still offers land info, because the ground under a track '
        'is the ground most walked', (tester) async {
      expect(
        await open(tester, _track(), tap: 'Land info'),
        isA<LandInfoFromCard>(),
      );
    });
  });

  testWidgets('a one-point track is treated as a point', (tester) async {
    final stub = Waypoint(
      id: 's1',
      name: 'One fix',
      latitude: 45.1,
      longitude: -77.1,
      notes: '',
      createdAt: DateTime.utc(2026, 9, 10),
      category: WaypointCategory.trail,
      track: const [TrackPoint(latitude: 45.1, longitude: -77.1)],
    );
    await open(tester, stub);
    // It draws nothing followable on the map, so offering to follow it would
    // promise a line that is not there.
    expect(find.text('Follow'), findsNothing);
    expect(find.byType(TrackPreview), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });
}
