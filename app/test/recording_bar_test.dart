import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/recording_bar.dart';
import 'package:open_woods_map/tracks/track_math.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

/// A straight walk east, one point roughly every 78 m at this latitude.
List<TrackPoint> _walk(int points) => [
  for (var i = 0; i < points; i++)
    TrackPoint(latitude: 45.1, longitude: -77.1 + i * 0.001),
];

void main() {
  Future<int> pumpBar(
    WidgetTester tester, {
    required List<TrackPoint> points,
    Duration elapsed = const Duration(minutes: 12),
    int rejected = 0,
  }) async {
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingBar(
            points: points,
            startedAt: clock.now().subtract(elapsed),
            rejectedFixes: rejected,
            onStop: () => stops++,
          ),
        ),
      ),
    );
    return stops;
  }

  testWidgets('says how far and how long', (tester) async {
    final points = _walk(5);
    await pumpBar(tester, points: points);
    expect(find.text('Recording a track'), findsOneWidget);
    // The walked length through the shared formatter, so the bar and the track
    // list can never disagree about how far the same walk was.
    expect(
      find.text(formatDistance(trackLengthMetres(points))),
      findsOneWidget,
    );
    expect(find.text('12 min'), findsOneWidget);
    expect(find.text('5 points'), findsOneWidget);
  });

  testWidgets('keeps counting while the walker stands still', (tester) async {
    // The clock is the bar's own, not the map's, because a stationary phone
    // produces fixes that are dropped as duplicates: nothing would rebuild this.
    await pumpBar(tester, points: _walk(5), elapsed: const Duration(hours: 1));
    expect(find.text('1h 00m'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('1h 01m'), findsOneWidget);
  });

  testWidgets('waits rather than claiming a distance it has not walked',
      (tester) async {
    await pumpBar(tester, points: _walk(1));
    expect(find.text('Waiting for a second fix…'), findsOneWidget);
    expect(find.text('1 points'), findsNothing);
  });

  group('dropped fixes', () {
    testWidgets('are said out loud while there is still time to act',
        (tester) async {
      await pumpBar(tester, points: _walk(40), rejected: 6);
      expect(find.text('40 points · 6 poor fixes dropped'), findsOneWidget);
    });

    testWidgets('read as one fix when there is one', (tester) async {
      await pumpBar(tester, points: _walk(40), rejected: 1);
      expect(find.text('40 points · 1 poor fix dropped'), findsOneWidget);
    });

    testWidgets('are not mentioned when there are none', (tester) async {
      await pumpBar(tester, points: _walk(40));
      expect(find.text('40 points'), findsOneWidget);
      expect(find.textContaining('dropped'), findsNothing);
    });
  });

  testWidgets('stops on request', (tester) async {
    var stopped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingBar(
            points: _walk(5),
            startedAt: DateTime.now(),
            rejectedFixes: 0,
            onStop: () => stopped = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.stop));
    expect(stopped, isTrue);
  });

  testWidgets('cancels its clock when it goes away', (tester) async {
    await pumpBar(tester, points: _walk(5));
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    // A leaked periodic timer fails the test on teardown, which is the whole
    // assertion: the bar is built and torn down on every recording.
    await tester.pump(const Duration(seconds: 5));
  });
}
