import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_follow.dart';
import 'package:open_woods_map/tracks/track_math.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

TrackPoint _at(double latitude, double longitude) =>
    TrackPoint(latitude: latitude, longitude: longitude);

/// Metres per degree of latitude on the sphere the code uses.
const _perLatDegree = 6371008.8 * 3.141592653589793 / 180.0;

/// Due north for 0.02 degrees, a little over 2.2 km, in five even steps.
final _northward = [
  _at(45.000, -75.0),
  _at(45.005, -75.0),
  _at(45.010, -75.0),
  _at(45.015, -75.0),
  _at(45.020, -75.0),
];

void main() {
  group('orientTrack', () {
    test('leaves a forward track alone', () {
      expect(orientTrack(_northward, reversed: false).first.latitude, 45.0);
    });

    test('reversing swaps the ends', () {
      final reversed = orientTrack(_northward, reversed: true);
      expect(reversed.first.latitude, 45.020);
      expect(reversed.last.latitude, 45.000);
    });

    test('does not disturb the original list', () {
      // The oriented list is handed to the map as well as to the maths, and a
      // reverse that mutated the stored track would corrupt the saved file.
      orientTrack(_northward, reversed: true);
      expect(_northward.first.latitude, 45.000);
    });
  });

  group('guidance', () {
    test('is null when there is no line to follow', () {
      expect(guidanceAlong([], 45, -75), isNull);
      expect(guidanceAlong([_at(45, -75)], 45, -75), isNull);
    });

    test('at the start, everything is still to go', () {
      final guidance = guidanceAlong(_northward, 45.000, -75.0)!;
      expect(guidance.travelledMetres, closeTo(0, 0.5));
      expect(
        guidance.remainingMetres,
        closeTo(trackLengthMetres(_northward), 0.5),
      );
      expect(guidance.arrived, isFalse);
      expect(guidance.offRoute, isFalse);
    });

    test('halfway along, the two halves add up to the whole', () {
      final total = trackLengthMetres(_northward);
      final guidance = guidanceAlong(_northward, 45.010, -75.0)!;
      expect(guidance.travelledMetres, closeTo(total / 2, 1));
      expect(
        guidance.travelledMetres + guidance.remainingMetres,
        closeTo(total, 0.5),
      );
    });

    test('at the far end it says so', () {
      final guidance = guidanceAlong(_northward, 45.020, -75.0)!;
      expect(guidance.remainingMetres, closeTo(0, 0.5));
      expect(guidance.arrived, isTrue);
    });

    test('remaining never goes negative past the end', () {
      // The projection clamps to the last leg, but rounding can put it a hair
      // beyond, and "-3 m to go" makes a user stop trusting the whole screen.
      final guidance = guidanceAlong(_northward, 45.05, -75.0)!;
      expect(guidance.remainingMetres, greaterThanOrEqualTo(0));
      expect(guidance.remainingMetres, closeTo(0, 0.5));
    });

    // The point of the whole feature: the same track walked the other way has to
    // report the other way round, with no special cases anywhere downstream.
    group('reversed', () {
      test('the start of the reverse is the end of the forward', () {
        final reversed = orientTrack(_northward, reversed: true);
        final guidance = guidanceAlong(reversed, 45.020, -75.0)!;
        expect(guidance.travelledMetres, closeTo(0, 0.5));
        expect(guidance.arrived, isFalse);
      });

      test('walking the reverse to its end arrives', () {
        final reversed = orientTrack(_northward, reversed: true);
        final guidance = guidanceAlong(reversed, 45.000, -75.0)!;
        expect(guidance.remainingMetres, closeTo(0, 0.5));
        expect(guidance.arrived, isTrue);
      });

      test('remaining and travelled swap at the same place on the ground', () {
        final forward = guidanceAlong(_northward, 45.005, -75.0)!;
        final reversed = guidanceAlong(
          orientTrack(_northward, reversed: true),
          45.005,
          -75.0,
        )!;
        expect(reversed.travelledMetres, closeTo(forward.remainingMetres, 1));
        expect(reversed.remainingMetres, closeTo(forward.travelledMetres, 1));
      });

      test('the heading is the opposite way down the same line', () {
        final forward = guidanceAlong(_northward, 45.005, -75.0)!;
        final reversed = guidanceAlong(
          orientTrack(_northward, reversed: true),
          45.005,
          -75.0,
        )!;
        expect(forward.headingAlong, closeTo(0, 1e-6));
        expect(reversed.headingAlong, closeTo(180, 1e-6));
      });
    });

    group('off route', () {
      test('a position on the line is not off route', () {
        final guidance = guidanceAlong(_northward, 45.010, -75.0)!;
        expect(guidance.offTrackMetres, closeTo(0, 0.5));
        expect(guidance.offRoute, isFalse);
        expect(guidance.bearingToTrack, isNull);
      });

      test('GPS-scale wander does not raise a warning', () {
        // About 22 m east of the line. Inside what the fix itself is uncertain
        // by, so claiming the user has left the track would be crying wolf.
        final guidance = guidanceAlong(_northward, 45.010, -74.99972)!;
        expect(guidance.offTrackMetres, lessThan(offRouteMetres));
        expect(guidance.offRoute, isFalse);
        expect(guidance.bearingToTrack, isNull);
      });

      test('genuinely leaving the track warns and points back', () {
        // 0.002 degrees of latitude worth of east offset, about 220 m.
        final guidance = guidanceAlong(_northward, 45.010, -74.99716)!;
        expect(guidance.offRoute, isTrue);
        expect(guidance.offTrackMetres, greaterThan(150));
        // The line is due west of the position.
        expect(guidance.bearingToTrack, closeTo(270, 1));
      });

      test('the point reported is on the track, not where the user is', () {
        final guidance = guidanceAlong(_northward, 45.010, -74.99716)!;
        expect(guidance.longitude, closeTo(-75.0, 1e-6));
        expect(guidance.latitude, closeTo(45.010, 1e-4));
      });

      test('being off to the side does not consume the track', () {
        // Distance remaining is measured along the line, so wandering sideways
        // must not make the end appear closer.
        final onLine = guidanceAlong(_northward, 45.010, -75.0)!;
        final beside = guidanceAlong(_northward, 45.010, -74.99716)!;
        expect(beside.remainingMetres, closeTo(onLine.remainingMetres, 2));
      });
    });

    test('a supplied cumulative list changes nothing', () {
      final shared = cumulativeMetres(_northward);
      final own = guidanceAlong(_northward, 45.007, -75.0)!;
      final reused = guidanceAlong(
        _northward,
        45.007,
        -75.0,
        cumulative: shared,
      )!;
      expect(reused.remainingMetres, closeTo(own.remainingMetres, 1e-9));
    });

    test('a track that doubles back does not jump the remaining distance', () {
      // Standing near where an out-and-back crosses itself, the nearer leg wins
      // and the answer has to be one of the two legs rather than an average.
      final outAndBack = [
        _at(45.000, -75.0),
        _at(45.010, -75.0),
        _at(45.010, -74.9999),
        _at(45.000, -74.9999),
      ];
      final guidance = guidanceAlong(outAndBack, 45.005, -74.99995)!;
      final total = trackLengthMetres(outAndBack);
      expect(guidance.offTrackMetres, lessThan(6));
      expect(guidance.remainingMetres, inInclusiveRange(0, total));
      expect(
        guidance.travelledMetres + guidance.remainingMetres,
        closeTo(total, 0.5),
      );
    });
  });

  group('compassPoint', () {
    test('names the cardinals', () {
      expect(compassPoint(0), 'N');
      expect(compassPoint(90), 'E');
      expect(compassPoint(180), 'S');
      expect(compassPoint(270), 'W');
    });

    test('rounds to the nearest of sixteen', () {
      expect(compassPoint(11), 'N');
      expect(compassPoint(12), 'NNE');
      expect(compassPoint(45), 'NE');
    });

    test('wraps rather than running off the end', () {
      expect(compassPoint(359), 'N');
      expect(compassPoint(360), 'N');
      expect(compassPoint(349), 'N');
      expect(compassPoint(348), 'NNW');
    });

    test('survives a negative bearing', () {
      expect(compassPoint(-90), 'W');
    });
  });

  group('the offset used by the tests is the offset intended', () {
    // Guards the fixtures above: if these offsets are not the distances the
    // comments claim, the off-route tests would be asserting nothing.
    test('22 m and 220 m east of the line', () {
      expect(
        metresBetween(45.010, -75.0, 45.010, -74.99972),
        closeTo(22, 2),
      );
      expect(
        metresBetween(45.010, -75.0, 45.010, -74.99716),
        closeTo(0.00284 * _perLatDegree * 0.7071, 6),
      );
    });
  });
}
