import '../waypoints/waypoint_store.dart';
import 'track_math.dart';

/// Following a saved track, forwards or in reverse.
///
/// The whole of this file is pure: it takes a position and a list of points and
/// returns numbers. Nothing here touches the map, the store or a plugin, because
/// these are the numbers a person is going to trust in the dark and they need to
/// be checkable without a device.

/// How far off the line a position has to be before this calls it off route.
///
/// Consumer GPS is uncertain by 10 to 20 m under canopy, and a track recorded
/// with the same hardware carries the same uncertainty, so anything closer than
/// this cannot honestly be distinguished from standing on the line. Warning
/// earlier would cry wolf on every bend of every track ever recorded in bush,
/// and a warning that is usually wrong is one people stop reading.
const offRouteMetres = 40.0;

/// How close to the far end counts as having got there.
const arrivedMetres = 25.0;

/// What to tell someone following a track right now.
class FollowGuidance {
  const FollowGuidance({
    required this.remainingMetres,
    required this.travelledMetres,
    required this.offTrackMetres,
    required this.latitude,
    required this.longitude,
    required this.headingAlong,
    required this.bearingToTrack,
  });

  /// Distance to the far end, following the track rather than as the crow flies.
  final double remainingMetres;

  /// Distance from the start of the track, in the direction being followed.
  final double travelledMetres;

  /// Shortest distance from the position to the line.
  final double offTrackMetres;

  /// The point on the track being measured from. Worth drawing: it is where the
  /// app thinks you are, and if that is wrong the user should be able to see it
  /// is wrong rather than be told a confident number about it.
  final double latitude;
  final double longitude;

  /// Where the track goes next from here, in degrees from true north. Null at
  /// the very end, where there is no next leg.
  final double? headingAlong;

  /// Which way to walk to get back on the line. Null when already on it, since
  /// a bearing over a few metres of GPS noise points nowhere useful.
  final double? bearingToTrack;

  bool get offRoute => offTrackMetres > offRouteMetres;

  bool get arrived => remainingMetres <= arrivedMetres;
}

/// Orients a track's points for the direction being followed.
///
/// Reversing the list rather than counting backwards through it means every
/// other calculation — distance along, distance remaining, which way the next leg
/// runs, and the direction the arrows point on the map — comes out right without
/// a single special case for reverse. Getting one of those backwards is how a
/// navigation feature sends someone the wrong way.
List<TrackPoint> orientTrack(List<TrackPoint> points, {required bool reversed}) =>
    reversed ? points.reversed.toList() : points;

/// Guidance for a position against an already-oriented track.
///
/// Returns null when there is no line to follow at all. [cumulative] can be
/// passed in to avoid recomputing the running distances on every fix.
FollowGuidance? guidanceAlong(
  List<TrackPoint> points,
  double latitude,
  double longitude, {
  List<double>? cumulative,
}) {
  if (points.length < 2) return null;
  final along = cumulative ?? cumulativeMetres(points);
  final projection = projectOntoTrack(
    points,
    latitude,
    longitude,
    cumulative: along,
  );
  if (projection == null) return null;

  final total = along.last;
  return FollowGuidance(
    // Clamped because the projection can land a hair past the end through
    // rounding, and "-3 m to go" is the kind of detail that makes someone stop
    // believing the rest of the screen.
    remainingMetres: (total - projection.alongMetres).clamp(0.0, total),
    travelledMetres: projection.alongMetres.clamp(0.0, total),
    offTrackMetres: projection.offTrackMetres,
    latitude: projection.latitude,
    longitude: projection.longitude,
    headingAlong: headingAt(points, projection.segmentIndex),
    bearingToTrack: projection.offTrackMetres > offRouteMetres
        ? bearingDegrees(
            latitude,
            longitude,
            projection.latitude,
            projection.longitude,
          )
        : null,
  );
}
