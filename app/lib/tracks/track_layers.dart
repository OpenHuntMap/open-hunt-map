import '../waypoints/waypoint_store.dart';
import 'track_style.dart';

/// The GeoJSON the map draws saved tracks from.
///
/// A top-level function rather than a method on the map shell so that it can be
/// tested. Every value in here crosses a Flutter method channel, and the codec
/// rejects anything that is not a plain JSON type with "Invalid argument:
/// Instance of X" from inside itself — naming neither the property nor the layer,
/// and taking the whole layer with it. A `Color` left in the properties by
/// mistake is exactly that failure, and it is silent on screen: the tracks
/// simply do not draw.
Map<String, dynamic> trackFeatureCollection(Iterable<Waypoint> tracks) => {
  'type': 'FeatureCollection',
  'features': [
    // A one-point track has no line to draw. It is kept in the list, where its
    // single fix is still a place the user went.
    for (final waypoint in tracks)
      if (waypoint.track.length >= 2)
        {
          'type': 'Feature',
          'properties': {
            'name': waypoint.name,
            'id': waypoint.id,
            // Per feature, so one layer draws every track in its own colour
            // rather than one layer per track.
            'colour': waypoint.colourHex,
            // Resolved here rather than in the style, because MapLibre has no
            // expression for "a colour that contrasts with this one".
            'arrow': markerHexFor(waypoint.displayColour),
            // Which line layer draws this track. Chosen here because
            // line-dasharray cannot vary per feature on Android or iOS, so the
            // stroke has to be a filter rather than a paint property.
            'stroke': waypoint.stroke.id,
            // The marker layer both reads this as its icon-image and filters on
            // it, so a track with no marker carries the empty string.
            'marker': waypoint.marker.image,
          },
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final point in waypoint.track)
                [point.longitude, point.latitude],
            ],
          },
        },
  ],
};
