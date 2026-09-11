import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_math.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

/// Reference distances and azimuths in this file were computed with pyproj's
/// `Geod(ellps='WGS84')`, which solves the geodesic on the ellipsoid. The code
/// under test works on a sphere, so the two disagree by up to about 0.45% at
/// Canadian latitudes; [_closeTo] allows that and nothing more. Checking against
/// an independent solver rather than against the same haversine formula is the
/// point — otherwise the test only proves the formula was transcribed twice.
void _closeTo(double actual, double expected, {double fraction = 0.005}) {
  expect(
    actual,
    closeTo(expected, expected.abs() * fraction),
    reason: 'expected about $expected, got $actual',
  );
}

/// Metres per degree of latitude on the sphere the code uses, for the synthetic
/// projection cases below.
const _metresPerLatDegree = 6371008.8 * 3.141592653589793 / 180.0;

TrackPoint _at(double latitude, double longitude, {DateTime? time}) =>
    TrackPoint(latitude: latitude, longitude: longitude, time: time);

void main() {
  group('metresBetween', () {
    test('is zero for the same point', () {
      expect(metresBetween(45, -75, 45, -75), 0);
    });

    test('matches a geodesic solver north-south', () {
      _closeTo(metresBetween(45, 0, 46, 0), 111141.55);
    });

    test('matches a geodesic solver east-west, where the sphere is worst', () {
      _closeTo(metresBetween(45, 0, 45, 1), 78846.33);
      _closeTo(metresBetween(0, 0, 0, 1), 111319.49);
      _closeTo(metresBetween(60, 0, 60, 1), 55799.47);
    });

    test('matches a geodesic solver over a few hundred kilometres', () {
      // Ottawa to Toronto.
      _closeTo(
        metresBetween(45.4215, -75.6972, 43.6532, -79.3832),
        352697.07,
      );
    });

    test('shrinks with latitude, which a missing cosine would not', () {
      final equator = metresBetween(0, 0, 0, 1);
      final ottawa = metresBetween(45, 0, 45, 1);
      final arctic = metresBetween(70, 0, 70, 1);
      expect(ottawa, lessThan(equator));
      expect(arctic, lessThan(ottawa));
    });

    test('is symmetric', () {
      expect(
        metresBetween(45.1, -75.2, 45.3, -75.4),
        closeTo(metresBetween(45.3, -75.4, 45.1, -75.2), 1e-9),
      );
    });
  });

  group('bearingDegrees', () {
    test('is exactly north and south for pure latitude changes', () {
      expect(bearingDegrees(45, -75, 46, -75), closeTo(0, 1e-9));
      expect(bearingDegrees(45, -75, 44, -75), closeTo(180, 1e-9));
    });

    test('is exactly east and west on the equator', () {
      expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 1e-9));
      expect(bearingDegrees(0, 0, 0, -1), closeTo(270, 1e-9));
    });

    test('is slightly less than due east away from the equator', () {
      // A great circle heading due east at 45 degrees north curves poleward, so
      // its initial bearing to a point at the same latitude is under 90. Not a
      // rounding artefact, and the reason a test asserting exactly 90 here
      // would be asserting the wrong thing.
      expect(bearingDegrees(45, 0, 45, 1), closeTo(89.646, 0.01));
      expect(bearingDegrees(60, 0, 60, 1), closeTo(89.567, 0.01));
    });

    test('matches a geodesic azimuth over a long line', () {
      expect(
        bearingDegrees(45.4215, -75.6972, 43.6532, -79.3832),
        closeTo(237.452, 0.25),
      );
    });

    test('is normalised into 0 to 360', () {
      for (final bearing in [
        bearingDegrees(45, -75, 44, -76),
        bearingDegrees(45, -75, 46, -76),
        bearingDegrees(45, -75, 44, -74),
      ]) {
        expect(bearing, greaterThanOrEqualTo(0));
        expect(bearing, lessThan(360));
      }
    });
  });

  group('trackLengthMetres', () {
    test('is zero for nothing and for a single point', () {
      expect(trackLengthMetres([]), 0);
      expect(trackLengthMetres([_at(45, -75)]), 0);
    });

    test('adds the legs', () {
      final points = [_at(45, -75), _at(45.001, -75), _at(45.002, -75)];
      _closeTo(trackLengthMetres(points), 2 * 0.001 * _metresPerLatDegree);
    });

    test('counts a doubled-back leg rather than the straight-line distance', () {
      // Out and back to the same place is not a zero-length track.
      final points = [_at(45, -75), _at(45.001, -75), _at(45, -75)];
      _closeTo(trackLengthMetres(points), 2 * 0.001 * _metresPerLatDegree);
    });
  });

  group('cumulativeMetres', () {
    test('starts at zero and ends at the total', () {
      final points = [_at(45, -75), _at(45.001, -75), _at(45.003, -75)];
      final cumulative = cumulativeMetres(points);
      expect(cumulative.length, points.length);
      expect(cumulative.first, 0);
      _closeTo(cumulative.last, trackLengthMetres(points), fraction: 1e-9);
    });

    test('never decreases', () {
      final points = [
        _at(45, -75),
        _at(45.001, -75.001),
        _at(45, -75.002),
        _at(45.002, -75.003),
      ];
      final cumulative = cumulativeMetres(points);
      for (var i = 1; i < cumulative.length; i++) {
        expect(cumulative[i], greaterThanOrEqualTo(cumulative[i - 1]));
      }
    });

    test('handles an empty track', () {
      expect(cumulativeMetres([]), isEmpty);
    });
  });

  group('trackDuration', () {
    test('is null when no point carries a time', () {
      expect(trackDuration([_at(45, -75), _at(45.001, -75)]), isNull);
    });

    test('spans first to last', () {
      final start = DateTime.utc(2026, 9, 11, 6);
      final points = [
        _at(45, -75, time: start),
        _at(45.001, -75, time: start.add(const Duration(minutes: 40))),
        _at(45.002, -75, time: start.add(const Duration(hours: 1, minutes: 5))),
      ];
      expect(trackDuration(points), const Duration(hours: 1, minutes: 5));
    });

    test('does not assume the points are in time order', () {
      // Imported files are not always sorted, and a negative duration would
      // render as nonsense rather than failing visibly.
      final start = DateTime.utc(2026, 9, 11, 6);
      final points = [
        _at(45.002, -75, time: start.add(const Duration(hours: 2))),
        _at(45, -75, time: start),
      ];
      expect(trackDuration(points), const Duration(hours: 2));
    });

    test('uses only the points that have times', () {
      final start = DateTime.utc(2026, 9, 11, 6);
      final points = [
        _at(45, -75),
        _at(45.001, -75, time: start),
        _at(45.002, -75, time: start.add(const Duration(minutes: 30))),
        _at(45.003, -75),
      ];
      expect(trackDuration(points), const Duration(minutes: 30));
    });

    test('is zero rather than null for a single timed point', () {
      final points = [_at(45, -75, time: DateTime.utc(2026, 9, 11))];
      expect(trackDuration(points), Duration.zero);
    });
  });

  group('projectOntoTrack', () {
    // East along latitude 45, then north.
    final lTrack = [
      _at(45.0, -75.0),
      _at(45.0, -74.99),
      _at(45.005, -74.99),
    ];

    test('is null only for an empty track', () {
      expect(projectOntoTrack([], 45, -75), isNull);
      expect(projectOntoTrack([_at(45, -75)], 45, -75), isNotNull);
    });

    test('a position on the first vertex is at distance zero along', () {
      final projection = projectOntoTrack(lTrack, 45.0, -75.0)!;
      expect(projection.offTrackMetres, closeTo(0, 0.01));
      expect(projection.alongMetres, closeTo(0, 0.01));
    });

    test('a position on the corner is at the first leg length along', () {
      final cumulative = cumulativeMetres(lTrack);
      final projection = projectOntoTrack(lTrack, 45.0, -74.99)!;
      expect(projection.offTrackMetres, closeTo(0, 0.01));
      _closeTo(projection.alongMetres, cumulative[1], fraction: 1e-6);
    });

    test('a position beside a leg gives the perpendicular distance', () {
      // 0.001 degrees of latitude north of the midpoint of the first leg.
      final projection = projectOntoTrack(lTrack, 45.001, -74.995)!;
      _closeTo(
        projection.offTrackMetres,
        0.001 * _metresPerLatDegree,
        fraction: 1e-3,
      );
      _closeTo(
        projection.alongMetres,
        cumulativeMetres(lTrack)[1] / 2,
        fraction: 1e-3,
      );
      expect(projection.segmentIndex, 0);
      // The returned point is on the track, not the position handed in.
      expect(projection.latitude, closeTo(45.0, 1e-9));
    });

    test('a position past the end clamps to the end', () {
      final total = trackLengthMetres(lTrack);
      final projection = projectOntoTrack(lTrack, 45.01, -74.99)!;
      _closeTo(projection.alongMetres, total, fraction: 1e-6);
      _closeTo(
        projection.offTrackMetres,
        0.005 * _metresPerLatDegree,
        fraction: 1e-3,
      );
    });

    test('a position before the start clamps to the start', () {
      final projection = projectOntoTrack(lTrack, 45.0, -75.01)!;
      expect(projection.alongMetres, closeTo(0, 0.01));
      expect(projection.segmentIndex, 0);
    });

    test('picks the nearest leg on a track that doubles back', () {
      // Out east, 22 m north, then back west almost over the outbound leg. A
      // projection that scanned for the nearest recorded point, or stopped at
      // the first leg within some tolerance, would report a position half a
      // kilometre adrift along the track and send follow-along the wrong way.
      final hairpin = [
        _at(45.0, -75.0),
        _at(45.0, -74.99),
        _at(45.0002, -74.99),
        _at(45.0002, -75.0),
      ];
      final projection = projectOntoTrack(hairpin, 45.00018, -74.995)!;
      expect(projection.segmentIndex, 2);
      _closeTo(
        projection.offTrackMetres,
        0.00002 * _metresPerLatDegree,
        fraction: 0.05,
      );
      final cumulative = cumulativeMetres(hairpin);
      _closeTo(
        projection.alongMetres,
        cumulative[2] + (cumulative[3] - cumulative[2]) / 2,
        fraction: 1e-3,
      );
    });

    test('a single-point track projects onto that point', () {
      final projection = projectOntoTrack([_at(45, -75)], 45.001, -75)!;
      expect(projection.alongMetres, 0);
      _closeTo(
        projection.offTrackMetres,
        0.001 * _metresPerLatDegree,
        fraction: 1e-3,
      );
    });

    test('a repeated fix does not divide by zero', () {
      final withDuplicate = [
        _at(45.0, -75.0),
        _at(45.0, -75.0),
        _at(45.001, -75.0),
      ];
      final projection = projectOntoTrack(withDuplicate, 45.0005, -75.0)!;
      expect(projection.offTrackMetres.isNaN, isFalse);
      expect(projection.alongMetres.isNaN, isFalse);
      expect(projection.offTrackMetres, closeTo(0, 0.01));
    });

    test('a supplied cumulative list gives the same answer', () {
      final own = projectOntoTrack(lTrack, 45.001, -74.995)!;
      final shared = projectOntoTrack(
        lTrack,
        45.001,
        -74.995,
        cumulative: cumulativeMetres(lTrack),
      )!;
      expect(shared.alongMetres, closeTo(own.alongMetres, 1e-9));
      expect(shared.segmentIndex, own.segmentIndex);
    });
  });

  group('headingAt', () {
    final points = [_at(45, -75), _at(46, -75), _at(46, -74)];

    test('reads the direction of the given leg', () {
      expect(headingAt(points, 0), closeTo(0, 1e-9));
      expect(headingAt(points, 1), closeTo(89.65, 0.1));
    });

    test('is null outside the legs', () {
      expect(headingAt(points, -1), isNull);
      // Index 2 is the last point, which starts no leg.
      expect(headingAt(points, 2), isNull);
      expect(headingAt(points, 99), isNull);
    });

    test('is null for a leg with no length rather than an arbitrary angle', () {
      expect(headingAt([_at(45, -75), _at(45, -75)], 0), isNull);
    });
  });

  group('formatDistance', () {
    test('uses metres below a kilometre', () {
      expect(formatDistance(0), '0 m');
      expect(formatDistance(7.4), '7 m');
      expect(formatDistance(950), '950 m');
    });

    test('rolls over to kilometres without printing 1000 m', () {
      expect(formatDistance(999.6), '1.0 km');
      expect(formatDistance(1000), '1.0 km');
    });

    test('drops the decimal once there are ten kilometres', () {
      expect(formatDistance(5432), '5.4 km');
      expect(formatDistance(12345), '12 km');
    });

    test('says nothing rather than NaN', () {
      expect(formatDistance(double.nan), '—');
      expect(formatDistance(double.infinity), '—');
    });
  });

  group('formatDuration', () {
    test('shows minutes under an hour', () {
      expect(formatDuration(Duration.zero), '0 min');
      expect(formatDuration(const Duration(minutes: 45)), '45 min');
    });

    test('pads the minutes once hours appear', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1h 05m');
      expect(formatDuration(const Duration(hours: 2)), '2h 00m');
      expect(formatDuration(const Duration(hours: 13, minutes: 59)), '13h 59m');
    });
  });
}
