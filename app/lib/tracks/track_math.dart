import 'dart:math' as math;

import '../waypoints/waypoint_store.dart';

/// Geometry for recorded tracks: how long one is, and where you are on it.
///
/// Everything here is a pure function over plain numbers so it can be tested
/// without a device, a plugin or a map. Follow-along navigation depends on
/// [projectOntoTrack] being right, and being wrong there means telling someone
/// they are on a trail when they are not.

/// Mean Earth radius, IUGG.
///
/// Distances here are great-circle on a sphere rather than geodesic on the WGS84
/// ellipsoid. Measured against WGS84 the error stays under 0.45% everywhere
/// between 41 and 83 degrees north, worst for east-west lines at the top of that
/// range and around 0.3% across southern Ontario. On a 5 km walk that is some
/// 15 m, well inside what the fixes themselves are uncertain by, so it is not
/// worth carrying a geodesic solver for. It does mean track lengths should never
/// be presented to a precision finer than [formatDistance] allows.
const _earthRadiusMetres = 6371008.8;

double _radians(double degrees) => degrees * math.pi / 180.0;

/// Great-circle distance in metres.
double metresBetween(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final phi1 = _radians(lat1);
  final phi2 = _radians(lat2);
  final dPhi = phi2 - phi1;
  final dLambda = _radians(lon2 - lon1);
  // Haversine rather than the spherical law of cosines, which loses precision
  // catastrophically for the short hops between consecutive GPS fixes.
  final a =
      math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) * math.cos(phi2) *
          math.sin(dLambda / 2) * math.sin(dLambda / 2);
  return 2 * _earthRadiusMetres * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Initial bearing from the first point to the second, in degrees clockwise
/// from true north, normalised to `[0, 360)`.
double bearingDegrees(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final phi1 = _radians(lat1);
  final phi2 = _radians(lat2);
  final dLambda = _radians(lon2 - lon1);
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  final degrees = math.atan2(y, x) * 180.0 / math.pi;
  return (degrees + 360.0) % 360.0;
}

/// Total walked length in metres. Zero for anything shorter than two points.
double trackLengthMetres(List<TrackPoint> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += metresBetween(
      points[i - 1].latitude,
      points[i - 1].longitude,
      points[i].latitude,
      points[i].longitude,
    );
  }
  return total;
}

/// Distance from the start of the track to each point, so `[0] == 0` and the
/// last entry is the total length.
///
/// Navigation asks "how much is left" on every position update, and recomputing
/// the whole sum each time is quadratic over a track with thousands of points.
List<double> cumulativeMetres(List<TrackPoint> points) {
  final result = List<double>.filled(points.length, 0.0);
  for (var i = 1; i < points.length; i++) {
    result[i] = result[i - 1] +
        metresBetween(
          points[i - 1].latitude,
          points[i - 1].longitude,
          points[i].latitude,
          points[i].longitude,
        );
  }
  return result;
}

/// Wall-clock span of the recording, or null when the points carry no times.
///
/// This is elapsed time including every stop, not moving time. A track recorded
/// over a lunch break says so, which is the honest reading of "how long did this
/// take" and the only one recoverable from timestamps alone.
Duration? trackDuration(List<TrackPoint> points) {
  DateTime? first;
  DateTime? last;
  for (final point in points) {
    final time = point.time;
    if (time == null) continue;
    if (first == null || time.isBefore(first)) first = time;
    if (last == null || time.isAfter(last)) last = time;
  }
  if (first == null || last == null) return null;
  return last.difference(first);
}

/// Where a position falls on a track.
class TrackProjection {
  const TrackProjection({
    required this.segmentIndex,
    required this.latitude,
    required this.longitude,
    required this.offTrackMetres,
    required this.alongMetres,
  });

  /// The segment running from `points[segmentIndex]` to
  /// `points[segmentIndex + 1]`. For a single-point track this is 0 and the
  /// projection is that point.
  final int segmentIndex;

  /// The closest point on the track itself, which is what a follow-along view
  /// should show rather than the raw fix.
  final double latitude;
  final double longitude;

  /// How far the position is from the track. This is the number that decides
  /// whether someone is still on route, so it is deliberately the shortest
  /// distance to the line and not to the nearest recorded point: on a track
  /// recorded with a 5 m filter those differ by metres, and on one imported at
  /// low resolution they differ by hundreds.
  final double offTrackMetres;

  /// Distance from the start of the track to the projected point, following the
  /// track. Subtract from the total to get what remains.
  final double alongMetres;
}

/// Projects a position onto the nearest place on a track.
///
/// Each segment is flattened into a local east-north plane before the
/// point-to-segment projection. Over the tens of metres between consecutive
/// fixes the resulting error is well under a centimetre, and it stays under a
/// metre for segments up to several kilometres, which is the worst case for a
/// coarsely imported route. A great-circle cross-track solution would be exact
/// and is not worth the complexity at these scales.
///
/// Returns null only for an empty list.
TrackProjection? projectOntoTrack(
  List<TrackPoint> points,
  double latitude,
  double longitude, {
  List<double>? cumulative,
}) {
  if (points.isEmpty) return null;
  if (points.length == 1) {
    return TrackProjection(
      segmentIndex: 0,
      latitude: points.first.latitude,
      longitude: points.first.longitude,
      offTrackMetres: metresBetween(
        latitude,
        longitude,
        points.first.latitude,
        points.first.longitude,
      ),
      alongMetres: 0,
    );
  }

  final along = cumulative ?? cumulativeMetres(points);
  var bestIndex = 0;
  var bestOffTrack = double.infinity;
  var bestLatitude = points.first.latitude;
  var bestLongitude = points.first.longitude;
  var bestAlong = 0.0;

  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    // Metres per degree at this latitude. Longitude degrees shrink towards the
    // poles, and at 50 degrees north they are already only 64% of a latitude
    // degree, so leaving the cosine out would skew every projection eastward.
    final metresPerLatDegree = _earthRadiusMetres * math.pi / 180.0;
    final metresPerLonDegree =
        metresPerLatDegree * math.cos(_radians(a.latitude));

    final ax = 0.0;
    final ay = 0.0;
    final bx = (b.longitude - a.longitude) * metresPerLonDegree;
    final by = (b.latitude - a.latitude) * metresPerLatDegree;
    final px = (longitude - a.longitude) * metresPerLonDegree;
    final py = (latitude - a.latitude) * metresPerLatDegree;

    final dx = bx - ax;
    final dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    // A repeated fix leaves a zero-length segment; projecting onto it would
    // divide by zero, and its start point is the right answer anyway.
    final t = lengthSquared == 0
        ? 0.0
        : ((px * dx + py * dy) / lengthSquared).clamp(0.0, 1.0);

    final offTrack = math.sqrt(
      math.pow(px - t * dx, 2) + math.pow(py - t * dy, 2),
    );
    if (offTrack >= bestOffTrack) continue;

    bestOffTrack = offTrack;
    bestIndex = i;
    bestLatitude = a.latitude + (b.latitude - a.latitude) * t;
    bestLongitude = a.longitude + (b.longitude - a.longitude) * t;
    bestAlong = along[i] + (along[i + 1] - along[i]) * t;
  }

  return TrackProjection(
    segmentIndex: bestIndex,
    latitude: bestLatitude,
    longitude: bestLongitude,
    offTrackMetres: bestOffTrack,
    alongMetres: bestAlong,
  );
}

/// The direction the track is heading at [segmentIndex], in degrees from true
/// north, or null when there is no segment to take a direction from.
double? headingAt(List<TrackPoint> points, int segmentIndex) {
  if (segmentIndex < 0 || segmentIndex + 1 >= points.length) return null;
  final a = points[segmentIndex];
  final b = points[segmentIndex + 1];
  if (a.latitude == b.latitude && a.longitude == b.longitude) return null;
  return bearingDegrees(a.latitude, a.longitude, b.latitude, b.longitude);
}

const _compassPoints = [
  'N', 'NNE', 'NE', 'ENE',
  'E', 'ESE', 'SE', 'SSE',
  'S', 'SSW', 'SW', 'WSW',
  'W', 'WNW', 'NW', 'NNW',
];

/// The 16-point compass name for a bearing.
///
/// Paired with the degrees rather than replacing them: the degrees are what a
/// compass is set to, and the name is what makes the number sanity-checkable at
/// a glance when the phone is being read in the dark.
String compassPoint(double bearing) =>
    _compassPoints[((((bearing % 360) + 360) % 360 + 11.25) / 22.5).floor() % 16];

/// Formats a distance the way a person reads one off a map.
///
/// Metres below a kilometre because that is the resolution that matters when
/// you are looking for a stand in the dark, and two significant figures above
/// it because a GPS track's length is not known to the metre over that range.
String formatDistance(double metres) {
  if (metres.isNaN || metres.isInfinite) return '—';
  // Rounded before the comparison, so 999.6 m reads as 1.0 km rather than
  // "1000 m".
  final rounded = metres.round();
  if (rounded.abs() < 1000) return '$rounded m';
  final km = metres / 1000.0;
  return '${km < 10 ? km.toStringAsFixed(1) : km.round()} km';
}

/// One line describing a track, for a list row or an editor header.
///
/// Falls back to the point count when the points carry no times, because an
/// imported file often has none and "3.2 km" alone reads as though the recording
/// was instantaneous.
String describeTrack(List<TrackPoint> points) {
  final distance = formatDistance(trackLengthMetres(points));
  final duration = trackDuration(points);
  if (duration == null || duration == Duration.zero) {
    return '$distance · ${points.length} points';
  }
  return '$distance · ${formatDuration(duration)}';
}

/// Formats an elapsed span. Hours only appear once there are some.
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '$minutes min';
  return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
}
