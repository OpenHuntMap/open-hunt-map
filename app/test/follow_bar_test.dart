import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/follow_bar.dart';
import 'package:open_woods_map/tracks/track_follow.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

final _track = Waypoint(
  id: 't1',
  name: 'Ridge loop',
  latitude: 45,
  longitude: -77,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 11),
  icon: WaypointIcon.trail,
  track: const [
    TrackPoint(latitude: 45, longitude: -77),
    TrackPoint(latitude: 45.02, longitude: -77),
  ],
);

FollowGuidance _guidance({
  double remaining = 1400,
  double travelled = 800,
  double offTrack = 3,
  double? heading = 82,
  double? bearingToTrack,
}) => FollowGuidance(
  remainingMetres: remaining,
  travelledMetres: travelled,
  offTrackMetres: offTrack,
  latitude: 45.01,
  longitude: -77,
  headingAlong: heading,
  bearingToTrack: bearingToTrack,
);

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    FollowGuidance? guidance,
    bool reversed = false,
    VoidCallback? onReverse,
    VoidCallback? onStop,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FollowBar(
          track: _track,
          reversed: reversed,
          guidance: guidance,
          onReverse: onReverse ?? () {},
          onStop: onStop ?? () {},
        ),
      ),
    ),
  );

  testWidgets('names the track it is following', (tester) async {
    await pumpBar(tester, guidance: _guidance());
    expect(find.text('Ridge loop'), findsOneWidget);
  });

  testWidgets('says which way round it is being walked', (tester) async {
    await pumpBar(tester, guidance: _guidance());
    expect(find.text('Forward'), findsOneWidget);

    await pumpBar(tester, guidance: _guidance(), reversed: true);
    expect(find.text('Reverse'), findsOneWidget);
  });

  testWidgets('before the first fix it says so rather than showing a zero', (
    tester,
  ) async {
    // "0 m to go" would be a confident wrong answer; not knowing yet is the
    // truth and it is short-lived.
    await pumpBar(tester);
    expect(find.text('Waiting for a position fix…'), findsOneWidget);
    expect(find.textContaining('to go'), findsNothing);
  });

  testWidgets('leads with the distance left, with progress beside it', (
    tester,
  ) async {
    await pumpBar(tester, guidance: _guidance(remaining: 1400, travelled: 800));
    expect(find.text('1.4 km to go'), findsOneWidget);
    expect(find.text('800 m done'), findsOneWidget);
  });

  testWidgets('on the track it names where the track goes next', (tester) async {
    await pumpBar(tester, guidance: _guidance(heading: 82));
    // Degrees for setting a compass, the compass point for checking the number
    // at a glance.
    expect(find.text('On the track · continues 82° E'), findsOneWidget);
  });

  testWidgets('at the end of a leg with no next heading it still reads', (
    tester,
  ) async {
    await pumpBar(tester, guidance: _guidance(heading: null));
    expect(find.text('On the track.'), findsOneWidget);
  });

  testWidgets('off the track it says how far and which way back', (
    tester,
  ) async {
    await pumpBar(
      tester,
      guidance: _guidance(offTrack: 220, bearingToTrack: 270),
    );
    expect(
      find.text('220 m off the track — head 270° W to rejoin it'),
      findsOneWidget,
    );
    // The next heading of the track is not what someone off it needs.
    expect(find.textContaining('continues'), findsNothing);
  });

  testWidgets('off the track with no bearing still gives the distance', (
    tester,
  ) async {
    await pumpBar(tester, guidance: _guidance(offTrack: 220));
    expect(find.text('220 m off the track'), findsOneWidget);
  });

  testWidgets('arriving replaces the distance rather than showing 0 m', (
    tester,
  ) async {
    await pumpBar(tester, guidance: _guidance(remaining: 4, travelled: 2200));
    expect(find.text('At the end'), findsOneWidget);
    expect(
      find.text('You have reached the end of this track.'),
      findsOneWidget,
    );
  });

  testWidgets('being off route wins over having arrived', (tester) async {
    // Standing 200 m from the finish along the line but 200 m off it is not
    // arriving, and saying so would be the more dangerous of the two readings.
    await pumpBar(
      tester,
      guidance: _guidance(remaining: 4, offTrack: 200, bearingToTrack: 90),
    );
    expect(find.textContaining('off the track'), findsOneWidget);
    expect(find.textContaining('reached the end'), findsNothing);
  });

  testWidgets('the reverse and stop buttons report back', (tester) async {
    var reversed = 0;
    var stopped = 0;
    await pumpBar(
      tester,
      guidance: _guidance(),
      onReverse: () => reversed++,
      onStop: () => stopped++,
    );

    await tester.tap(find.byTooltip('Follow in reverse'));
    await tester.pump();
    expect(reversed, 1);

    await tester.tap(find.byTooltip('Stop following'));
    await tester.pump();
    expect(stopped, 1);
  });

  testWidgets('the reverse tooltip changes once reversed', (tester) async {
    await pumpBar(tester, guidance: _guidance(), reversed: true);
    expect(find.byTooltip('Follow the other way'), findsOneWidget);
  });
}
