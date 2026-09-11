import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';

void main() {
  group('the glyph in the list is the glyph on the map', () {
    // The list draws a Flutter IconData and the map draws an SDF PNG generated
    // from a codepoint by tools/icons/build_waypoint_icons.py. Nothing in the
    // build makes those the same glyph, so this is what stops them drifting: a
    // category whose icon is changed in Dart and not regenerated fails here
    // rather than shipping one symbol in the list and a different one on the
    // map.
    late Map<String, dynamic> manifest;

    setUpAll(() {
      final file = File('assets/waypoint_icons/manifest.json');
      manifest =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('every category has a generated image', () {
      final icons = manifest['icons'] as Map<String, dynamic>;
      for (final category in WaypointCategory.values) {
        expect(
          icons.containsKey(category.id),
          isTrue,
          reason:
              'No generated glyph for "${category.id}". Run '
              'python tools/icons/build_waypoint_icons.py',
        );
        expect(
          File('assets/waypoint_icons/${category.id}.png').existsSync(),
          isTrue,
          reason: 'assets/waypoint_icons/${category.id}.png is missing',
        );
      }
    });

    test('the generated glyph is the same codepoint the list draws', () {
      final icons = manifest['icons'] as Map<String, dynamic>;
      for (final category in WaypointCategory.values) {
        expect(
          icons[category.id],
          category.icon.codePoint,
          reason:
              '"${category.id}" draws U+${category.icon.codePoint.toRadixString(16)} '
              'in the list but its PNG was built from '
              'U+${(icons[category.id] as int).toRadixString(16)}',
        );
      }
    });

    test('no category shares an image name with another', () {
      final names = WaypointCategory.values.map((c) => c.iconImage).toSet();
      expect(names, hasLength(WaypointCategory.values.length));
    });
  });

  group('resolving a category', () {
    test('by its own id', () {
      expect(WaypointCategory.fromId('stand'), WaypointCategory.stand);
    });

    test('by a Garmin symbol name, which is how a GPX round trip survives', () {
      expect(WaypointCategory.fromId('Tree Stand'), WaypointCategory.stand);
      expect(WaypointCategory.fromId('Animal Tracks'), WaypointCategory.sign);
    });

    test('by a KML folder label, for a file Google Earth rewrote', () {
      expect(WaypointCategory.fromId('Water source'), WaypointCategory.water);
    });

    test('ignoring case and surrounding space', () {
      expect(WaypointCategory.fromId('  TREE STAND '), WaypointCategory.stand);
    });

    // Losing the category is acceptable. Losing the waypoint is not, so an
    // unknown id has to resolve rather than throw.
    test('anything unrecognised lands in other rather than throwing', () {
      expect(WaypointCategory.fromId('Geocache'), WaypointCategory.other);
      expect(WaypointCategory.fromId(null), WaypointCategory.other);
      expect(WaypointCategory.fromId(''), WaypointCategory.other);
    });
  });

  group('Garmin symbols', () {
    // These strings are the display names from GPSBabel's garmin_icon_tables.h.
    // A near miss is silently ignored by the unit and falls back to a default
    // pin, so the exact spelling is the whole value of the field.
    test('are spelled the way Garmin spells them', () {
      expect(WaypointCategory.stand.garminSym, 'Tree Stand');
      expect(WaypointCategory.blind.garminSym, 'Blind');
      expect(WaypointCategory.sign.garminSym, 'Animal Tracks');
      expect(WaypointCategory.blood.garminSym, 'Blood Trail');
      expect(WaypointCategory.food.garminSym, 'Food Source');
      expect(WaypointCategory.water.garminSym, 'Water Source');
      expect(WaypointCategory.trailhead.garminSym, 'Trail Head');
      expect(WaypointCategory.parking.garminSym, 'Parking Area');
    });

    // Garmin's vocabulary predates trail cameras. Inventing a name would put a
    // wrong icon on the unit, which is worse than the default one.
    test('are omitted where Garmin has nothing that fits', () {
      expect(WaypointCategory.camera.garminSym, isNull);
    });

    // GPX's trkType has no `sym` element at all, so there is nothing for a line
    // category's symbol to be written into and nothing to be gained by guessing.
    test('are absent on every line category', () {
      for (final category in WaypointCategory.values.where(
        (category) => category.shape == CategoryShape.line,
      )) {
        expect(category.garminSym, isNull, reason: category.id);
      }
    });
  });

  group('what a category can describe', () {
    test('points exclude the line-only categories', () {
      expect(WaypointCategory.forPoints, contains(WaypointCategory.stand));
      expect(
        WaypointCategory.forPoints,
        isNot(contains(WaypointCategory.portage)),
      );
    });

    test('lines exclude the point-only categories', () {
      expect(WaypointCategory.forLines, contains(WaypointCategory.trail));
      expect(WaypointCategory.forLines, isNot(contains(WaypointCategory.stand)));
    });

    test('the ones that work as either appear in both lists', () {
      for (final category in [
        WaypointCategory.other,
        WaypointCategory.hazard,
        // Followed rather than pinned as often as not.
        WaypointCategory.blood,
      ]) {
        expect(WaypointCategory.forPoints, contains(category));
        expect(WaypointCategory.forLines, contains(category));
      }
    });

    test('every category is offered somewhere', () {
      for (final category in WaypointCategory.values) {
        expect(
          WaypointCategory.forPoints.contains(category) ||
              WaypointCategory.forLines.contains(category),
          isTrue,
          reason: '${category.id} cannot be chosen at all',
        );
      }
    });

    test('a line category still resolves from a file', () {
      expect(WaypointCategory.fromId('portage'), WaypointCategory.portage);
      expect(
        WaypointCategory.fromId('Boundary walked'),
        WaypointCategory.boundary,
      );
    });
  });

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
      category: WaypointCategory.stand,
    );

    test('falls back to the category when none was chosen', () {
      expect(base.displayColour, WaypointCategory.stand.colour);
      expect(base.colourHex, hexColour(WaypointCategory.stand.colour));
    });

    test('overrides the category when one was chosen', () {
      final red = base.copyWith(colour: WaypointColour.red);
      expect(red.displayColour, WaypointColour.red.value);
    });

    // Passing colour: null cannot mean "unset", because that is what not
    // passing it looks like. Hence the separate flag.
    test('can be cleared back to following the category', () {
      final red = base.copyWith(colour: WaypointColour.red);
      expect(red.copyWith(clearColour: true).colour, isNull);
      expect(red.copyWith(name: 'Renamed').colour, WaypointColour.red);
    });
  });

  group('reading a file from an older build', () {
    // A waypoint saved before categories existed is not corrupt, it is
    // uncategorised, and it has to survive being loaded by this build.
    test('a waypoint with no category, tags or colour still loads', () {
      final waypoint = Waypoint.fromJson({
        'id': '1',
        'name': 'Old stand',
        'lat': 45.5,
        'lng': -77.5,
        'notes': 'From before categories',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'track': <Object>[],
      });

      expect(waypoint.name, 'Old stand');
      expect(waypoint.category, WaypointCategory.other);
      expect(waypoint.tags, isEmpty);
      expect(waypoint.colour, isNull);
    });

    test('a category id this build does not know becomes other', () {
      final waypoint = Waypoint.fromJson({
        'id': '1',
        'name': 'From a later build',
        'lat': 45.5,
        'lng': -77.5,
        'notes': '',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'category': 'mineral-lick',
        'tags': ['Ridge', 'ridge'],
      });

      expect(waypoint.category, WaypointCategory.other);
      expect(waypoint.tags, ['ridge']);
    });
  });
}
