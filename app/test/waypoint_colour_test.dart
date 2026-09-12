import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

void main() {
  group('colour encoding', () {
    test('MapLibre wants #RRGGBB', () {
      expect(hexColour(const Color(0xFFB3261E)), '#B3261E');
      expect(hexColour(const Color(0xFF000000)), '#000000');
    });

    // KML reverses the byte order, which is the standing cause of a red
    // waypoint arriving blue in Google Earth.
    test('KML wants aabbggrr, which is reversed', () {
      expect(kmlColour(const Color(0xFFB3261E)), 'ff1e26b3');
      expect(kmlColour(const Color(0xFF0000FF)), 'ffff0000');
    });
  });

  group('tags', () {
    test('are lowercased, trimmed and de-duplicated', () {
      expect(normaliseTags(['Ridge', 'ridge ', ' RIDGE']), ['ridge']);
    });

    test('keep the order they were first seen in', () {
      expect(normaliseTags(['north', 'ridge', 'north']), ['north', 'ridge']);
    });

    test('drop blanks rather than carrying an empty chip', () {
      expect(normaliseTags(['', '  ', 'ridge']), ['ridge']);
    });
  });

  group('a waypoint colour', () {
    final base = Waypoint(
      id: '1',
      name: 'Stand',
      latitude: 45.5,
      longitude: -77.5,
      notes: '',
      createdAt: DateTime.utc(2026, 9, 10),
      icon: WaypointIcon.stand,
    );

    test('falls back to the glyph it draws as', () {
      expect(base.displayColour, WaypointIcon.stand.colour);
      expect(base.colourHex, hexColour(WaypointIcon.stand.colour));
    });

    // Thirty unstyled waypoints have to be a legible spread of colour rather
    // than thirty identical pins, which is the whole reason the glyph carries
    // one.
    test('follows the glyph when the glyph changes', () {
      expect(
        base.copyWith(icon: WaypointIcon.portage).displayColour,
        WaypointIcon.portage.colour,
      );
      expect(
        base.copyWith(icon: WaypointIcon.portage).displayColour,
        isNot(base.displayColour),
      );
    });

    test('overrides the glyph when one was chosen', () {
      final red = base.copyWith(colour: WaypointColour.red);
      expect(red.displayColour, WaypointColour.red.value);
    });

    // Passing colour: null cannot mean "unset", because that is what not
    // passing it looks like. Hence the separate flag.
    test('can be cleared back to following the glyph', () {
      final purple = base.copyWith(colour: WaypointColour.purple);
      expect(purple.copyWith(clearColour: true).colour, isNull);
      expect(purple.copyWith(name: 'Renamed').colour, WaypointColour.purple);
    });

    // These look identical on screen wherever a glyph's colour happens to match
    // a named one, which is exactly why they are stored differently: only the
    // first follows the glyph if the user picks a different picture.
    test('following the glyph is not the same as being set to its colour', () {
      final pinned = Waypoint(
        id: '2',
        name: 'Pin',
        latitude: 45.5,
        longitude: -77.5,
        notes: '',
        createdAt: DateTime.utc(2026, 9, 10),
        colour: WaypointColour.red,
      );
      expect(pinned.displayColour, WaypointIcon.pin.colour);
      expect(
        pinned.copyWith(icon: WaypointIcon.portage).displayColour,
        WaypointColour.red.value,
      );
      expect(pinned.colour, isNotNull);
      expect(base.colour, isNull);
    });
  });

  group('resolving a colour id', () {
    test('every id round trips', () {
      for (final colour in WaypointColour.values) {
        expect(WaypointColour.fromId(colour.id), colour);
      }
    });

    test('absent and unknown are both null, not a default', () {
      expect(WaypointColour.fromId(null), isNull);
      expect(WaypointColour.fromId('chartreuse'), isNull);
    });
  });
}
