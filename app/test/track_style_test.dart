import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';

void main() {
  group('the direction marker images', () {
    late Map<String, dynamic> manifest;

    setUpAll(() {
      manifest =
          jsonDecode(
                File('assets/waypoint_icons/manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    test('every drawn marker is generated and bundled', () {
      // A symbol layer whose icon-image is missing draws nothing at all and
      // reports nothing about why, so a marker going absent would look like
      // MapLibre ignoring symbol-placement rather than a missing file.
      final extras = manifest['extras'] as Map<String, dynamic>;
      for (final marker in TrackMarker.drawn) {
        final key = marker.asset!.split('/').last.replaceAll('.png', '');
        expect(
          extras.containsKey(key),
          isTrue,
          reason:
              'Add ${marker.id} to EXTRAS and run '
              'python tools/icons/build_waypoint_icons.py',
        );
        expect(
          File(marker.asset!).existsSync(),
          isTrue,
          reason: '${marker.asset} is what rootBundle.load is given',
        );
      }
    });

    test('the glyph in the preview is the glyph on the map', () {
      // The picker draws marker.icon with a TextPainter while the map draws a
      // PNG baked from the codepoint in the manifest. If those drift, the
      // preview promises a shape the map does not draw — and the preview is the
      // only thing the user sees before saving.
      final extras = manifest['extras'] as Map<String, dynamic>;
      for (final marker in TrackMarker.drawn) {
        final key = marker.asset!.split('/').last.replaceAll('.png', '');
        expect(
          marker.icon!.codePoint,
          extras[key],
          reason: '${marker.id} preview and map glyphs have diverged',
        );
      }
    });

    test('none has no image, and it is the empty string the filter tests', () {
      // The marker layer filters on `['!=', ['get','marker'], '']`, so this
      // being anything else silently draws a missing icon on every unmarked
      // track.
      expect(TrackMarker.none.image, '');
      expect(TrackMarker.none.draws, isFalse);
      expect(TrackMarker.none.asset, isNull);
      expect(TrackMarker.drawn, isNot(contains(TrackMarker.none)));
    });

    test('no marker image collides with a category image name', () {
      final names = WaypointCategory.values.map((c) => c.iconImage).toSet();
      for (final marker in TrackMarker.drawn) {
        expect(names, isNot(contains(marker.image)));
      }
    });
  });

  group('stroke patterns', () {
    test('solid has no dash array at all', () {
      // MapLibre rejects an empty array, so absence has to be null rather than
      // a zero-length list.
      expect(TrackStroke.solid.dash, isNull);
    });

    test('every patterned stroke has positive lengths', () {
      for (final stroke in TrackStroke.values) {
        for (final length in stroke.dash ?? const <double>[]) {
          expect(
            length,
            greaterThan(0),
            reason: '${stroke.id} has a zero-length dash, which may not render',
          );
        }
      }
    });

    test('dotted has a round cap, which is what makes the dots dots', () {
      expect(TrackStroke.dotted.cap, 'round');
      expect(TrackStroke.dotted.dash!.first, lessThan(1));
    });

    test('dashed gaps survive its cap', () {
      // Round caps add half a line width to both ends of every dash. On a
      // dashed line that closes the gaps until it reads as solid, so this one
      // must not have them.
      expect(TrackStroke.dashed.cap, 'butt');
    });

    test('ids are stable and unique, because they are written to files', () {
      final ids = TrackStroke.values.map((stroke) => stroke.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, containsAll(['solid', 'dashed', 'dotted']));
    });
  });

  group('reading a look back', () {
    test('an unknown or absent stroke falls back to solid', () {
      expect(TrackStroke.fromId(null), TrackStroke.solid);
      expect(TrackStroke.fromId('squiggly'), TrackStroke.solid);
      expect(TrackStroke.fromId(''), TrackStroke.solid);
    });

    test('an unknown or absent marker falls back to arrows', () {
      // Absent means a track saved before the look was choosable, and those have
      // always been drawn with arrows.
      expect(TrackMarker.fromId(null), TrackMarker.arrow);
      expect(TrackMarker.fromId('barbed'), TrackMarker.arrow);
    });

    test('every id round trips', () {
      for (final stroke in TrackStroke.values) {
        expect(TrackStroke.fromId(stroke.id), stroke);
      }
      for (final marker in TrackMarker.values) {
        expect(TrackMarker.fromId(marker.id), marker);
      }
    });

    test('marker ids are unique', () {
      final ids = TrackMarker.values.map((marker) => marker.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('the marker colour', () {
    test('is light on a dark track and dark on a light one', () {
      expect(markerColourFor(const Color(0xFF212121)), Colors.white);
      expect(markerColourFor(const Color(0xFFFAFAFA)), const Color(0xFF212121));
    });

    // These two are the reason the colour is computed rather than fixed white:
    // a white marker on a white or yellow track is an invisible marker, and
    // those are colours a user picks deliberately for contrast against dark
    // ground.
    test('stays visible on the white and yellow track colours', () {
      expect(markerColourFor(WaypointColour.white.value), isNot(Colors.white));
      expect(markerColourFor(WaypointColour.yellow.value), isNot(Colors.white));
    });

    test('every track colour gets a marker that is not its own colour', () {
      for (final colour in WaypointColour.values) {
        expect(
          hexColour(markerColourFor(colour.value)),
          isNot(hexColour(colour.value)),
          reason: '${colour.id} markers would vanish into the line',
        );
      }
    });

    test('every category colour gets a marker that is not its own colour', () {
      for (final category in WaypointCategory.values) {
        expect(
          hexColour(markerColourFor(category.colour)),
          isNot(hexColour(category.colour)),
          reason: '${category.id} markers would vanish into the line',
        );
      }
    });
  });

  group('track line colour', () {
    test('follows the category when no override is set', () {
      expect(
        trackLineColour(null, WaypointCategory.portage),
        hexColour(WaypointCategory.portage.colour),
      );
    });

    test('an override wins', () {
      expect(
        trackLineColour(WaypointColour.red, WaypointCategory.portage),
        hexColour(WaypointColour.red.value),
      );
    });
  });
}
