import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_layers.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

Waypoint _track(
  String id, {
  TrackStroke stroke = TrackStroke.solid,
  TrackMarker marker = TrackMarker.arrow,
  WaypointColour? colour,
  WaypointIcon icon = WaypointIcon.trail,
  int points = 2,
}) => Waypoint(
  id: id,
  name: 'Ridge $id',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  icon: icon,
  colour: colour,
  stroke: stroke,
  marker: marker,
  track: [
    for (var i = 0; i < points; i++)
      TrackPoint(latitude: 45.1 + i * 0.01, longitude: -77.1 + i * 0.01),
  ],
);

Map<String, dynamic> _properties(Map<String, dynamic> collection) =>
    (collection['features'] as List).single['properties']
        as Map<String, dynamic>;

void main() {
  // This is the test that pays for the file existing. Every value crosses a
  // method channel, whose codec rejects anything that is not a plain JSON type
  // with an error naming neither the property nor the layer — and on screen the
  // tracks just silently do not draw. A Color left in the properties by mistake
  // is exactly that, and it happened.
  group('everything in it survives the method channel', () {
    test('a full set of looks and colours encodes as JSON', () {
      final tracks = [
        for (final stroke in TrackStroke.values)
          for (final marker in TrackMarker.values)
            _track('$stroke-$marker', stroke: stroke, marker: marker),
        for (final colour in WaypointColour.values)
          _track('c-$colour', colour: colour),
        for (final icon in WaypointIcon.values) _track('k-$icon', icon: icon),
      ];

      final collection = trackFeatureCollection(tracks);
      expect(() => jsonEncode(collection), returnsNormally);
    });

    test('every property value is a string, and none is empty by accident', () {
      final properties = _properties(trackFeatureCollection([_track('t1')]));

      for (final entry in properties.entries) {
        expect(
          entry.value,
          isA<String>(),
          reason: '${entry.key} is not a plain JSON type',
        );
      }
      expect(properties['colour'], startsWith('#'));
      expect(properties['arrow'], startsWith('#'));
    });
  });

  group('what the layers read', () {
    test('the stroke id picks the line layer', () {
      for (final stroke in TrackStroke.values) {
        final properties = _properties(
          trackFeatureCollection([_track('t1', stroke: stroke)]),
        );
        expect(properties['stroke'], stroke.id);
      }
    });

    test('the marker property is the image name the icon-image resolves', () {
      for (final marker in TrackMarker.drawn) {
        final properties = _properties(
          trackFeatureCollection([_track('t1', marker: marker)]),
        );
        expect(properties['marker'], marker.image);
        expect(properties['marker'], isNotEmpty);
      }
    });

    // The marker layer filters on `['!=', ['get','marker'], '']`, so this is
    // what keeps an unmarked track out of it rather than in it with a missing
    // icon.
    test('a track with no marker carries the empty string', () {
      final properties = _properties(
        trackFeatureCollection([_track('t1', marker: TrackMarker.none)]),
      );
      expect(properties['marker'], '');
    });

    test('the marker colour contrasts with the line, per track', () {
      final white = _properties(
        trackFeatureCollection([_track('t1', colour: WaypointColour.white)]),
      );
      final black = _properties(
        trackFeatureCollection([_track('t2', colour: WaypointColour.black)]),
      );

      expect(white['arrow'], isNot(white['colour']));
      expect(black['arrow'], isNot(black['colour']));
      expect(white['arrow'], isNot(black['arrow']));
    });
  });

  group('what gets a feature at all', () {
    test('a one-point track has no line and is left out', () {
      final collection = trackFeatureCollection([_track('t1', points: 1)]);
      expect(collection['features'], isEmpty);
    });

    test('coordinates are longitude first, as GeoJSON requires', () {
      final collection = trackFeatureCollection([_track('t1')]);
      final coordinates =
          (collection['features'] as List).single['geometry']['coordinates']
              as List;

      expect(coordinates.first, [-77.1, 45.1]);
    });

    test('point order is preserved, because it is the direction', () {
      final collection = trackFeatureCollection([_track('t1', points: 4)]);
      final coordinates =
          (collection['features'] as List).single['geometry']['coordinates']
              as List;

      final longitudes = [
        for (final pair in coordinates) (pair as List).first as double,
      ];
      expect(longitudes, hasLength(4));
      // Increasing rather than a list of literals: the fixture's own arithmetic
      // does not land on exact hundredths, and what matters here is only that
      // the walk is not handed to the map back to front.
      for (var i = 1; i < longitudes.length; i++) {
        expect(longitudes[i], greaterThan(longitudes[i - 1]));
      }
    });
  });
}
