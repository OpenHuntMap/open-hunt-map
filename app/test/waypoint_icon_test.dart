import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';

void main() {
  group('the glyph in the list is the glyph on the map', () {
    // The list draws a Flutter IconData and the map draws an SDF PNG generated
    // from a codepoint by tools/icons/build_waypoint_icons.py. Nothing in the
    // build makes those the same glyph, so this is what stops them drifting: an
    // icon whose codepoint is changed in Dart and not regenerated fails here
    // rather than shipping one symbol in the list and a different one on the
    // map.
    late Map<String, dynamic> manifest;

    setUpAll(() {
      final file = File('assets/waypoint_icons/manifest.json');
      manifest =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('every icon has a generated image', () {
      final icons = manifest['icons'] as Map<String, dynamic>;
      for (final icon in WaypointIcon.values) {
        expect(
          icons.containsKey(icon.id),
          isTrue,
          reason:
              'No generated glyph for "${icon.id}". Run '
              'python tools/icons/build_waypoint_icons.py',
        );
        expect(
          File('assets/waypoint_icons/${icon.id}.png').existsSync(),
          isTrue,
          reason: 'assets/waypoint_icons/${icon.id}.png is missing',
        );
      }
    });

    test('the generated glyph is the same codepoint the list draws', () {
      final icons = manifest['icons'] as Map<String, dynamic>;
      for (final icon in WaypointIcon.values) {
        expect(
          icons[icon.id],
          icon.icon.codePoint,
          reason:
              '"${icon.id}" draws U+${icon.icon.codePoint.toRadixString(16)} '
              'in the list but its PNG was built from '
              'U+${(icons[icon.id] as int).toRadixString(16)}',
        );
      }
    });

    // An id in the manifest with no icon to draw it is a PNG nothing loads and
    // a codepoint nothing checks, which is how a removed icon leaves litter.
    test('the manifest has nothing the app does not draw', () {
      final icons = (manifest['icons'] as Map<String, dynamic>).keys.toSet();
      expect(icons, WaypointIcon.values.map((icon) => icon.id).toSet());
    });

    test('no icon shares an image name with another', () {
      final names = WaypointIcon.values.map((icon) => icon.iconImage).toSet();
      expect(names, hasLength(WaypointIcon.values.length));
    });
  });

  group('resolving an icon', () {
    test('by its own id', () {
      expect(WaypointIcon.fromId('stand'), WaypointIcon.stand);
    });

    test('by a Garmin symbol name, which is how a GPX round trip survives', () {
      expect(WaypointIcon.fromId('Tree Stand'), WaypointIcon.stand);
      expect(WaypointIcon.fromId('Animal Tracks'), WaypointIcon.sign);
    });

    test('by a label, for a KML file Google Earth rewrote', () {
      expect(WaypointIcon.fromId('Water source'), WaypointIcon.water);
      expect(WaypointIcon.fromId('Tent'), WaypointIcon.tent);
    });

    test('ignoring case and surrounding space', () {
      expect(WaypointIcon.fromId('  TREE STAND '), WaypointIcon.stand);
    });

    // Losing the glyph is acceptable. Losing the waypoint is not, so an
    // unknown id has to resolve rather than throw.
    test('anything unrecognised lands on the pin rather than throwing', () {
      expect(WaypointIcon.fromId('mineral-lick'), WaypointIcon.pin);
      expect(WaypointIcon.fromId(null), WaypointIcon.pin);
      expect(WaypointIcon.fromId(''), WaypointIcon.pin);
      expect(WaypointIcon.fromId('   '), WaypointIcon.pin);
    });

    test('every id round trips', () {
      for (final icon in WaypointIcon.values) {
        expect(WaypointIcon.fromId(icon.id), icon, reason: icon.id);
      }
    });

    test('the default is the generic pin', () {
      expect(WaypointIcon.fallback, WaypointIcon.pin);
    });
  });

  group('Garmin symbols', () {
    // These strings are the display names from GPSBabel's garmin_icon_tables.h.
    // A near miss is silently ignored by the unit and falls back to a default
    // pin, so the exact spelling is the whole value of the field. They are the
    // one reason this is a closed set of icons rather than free codepoints.
    test('are spelled the way Garmin spells them', () {
      expect(WaypointIcon.pin.garminSym, 'Waypoint');
      expect(WaypointIcon.stand.garminSym, 'Tree Stand');
      expect(WaypointIcon.blind.garminSym, 'Blind');
      expect(WaypointIcon.sign.garminSym, 'Animal Tracks');
      expect(WaypointIcon.blood.garminSym, 'Blood Trail');
      expect(WaypointIcon.harvest.garminSym, 'Big Game');
      expect(WaypointIcon.food.garminSym, 'Food Source');
      expect(WaypointIcon.water.garminSym, 'Water Source');
      expect(WaypointIcon.camp.garminSym, 'Campground');
      expect(WaypointIcon.parking.garminSym, 'Parking Area');
      expect(WaypointIcon.trailhead.garminSym, 'Trail Head');
      expect(WaypointIcon.fishing.garminSym, 'Fishing Area');
      expect(WaypointIcon.viewpoint.garminSym, 'Summit');
      expect(WaypointIcon.hazard.garminSym, 'Skull and Crossbones');
    });

    // Garmin's vocabulary predates trail cameras. Inventing a name would put a
    // wrong icon on the unit, which is worse than the default one.
    test('are omitted where Garmin has nothing that fits', () {
      expect(WaypointIcon.camera.garminSym, isNull);
    });

    // Every glyph added since the icon stopped being a category. Garmin may
    // well have a "Boat Ramp" or a "Geocache", but the display name has to be
    // confirmed against the table rather than guessed, and an unconfirmed
    // guess is a wrong icon on someone's device.
    test('are absent on every glyph whose name has not been confirmed', () {
      for (final icon in [
        WaypointIcon.tent,
        WaypointIcon.firepit,
        WaypointIcon.cache,
        WaypointIcon.foraging,
        WaypointIcon.dock,
        WaypointIcon.boatLaunch,
        WaypointIcon.signpost,
        WaypointIcon.ford,
      ]) {
        expect(icon.garminSym, isNull, reason: icon.id);
      }
    });

    // GPX's trkType has no `sym` element at all, so there is nothing for one of
    // these to be written into and nothing to be gained by guessing.
    test('are absent on every line glyph', () {
      for (final icon in WaypointIcon.values.where(
        (icon) => icon.group == WaypointIconGroup.lines,
      )) {
        expect(icon.garminSym, isNull, reason: icon.id);
      }
    });

    test('no two icons claim the same Garmin symbol', () {
      final syms = [
        for (final icon in WaypointIcon.values)
          if (icon.garminSym case final sym?) sym,
      ];
      expect(syms.toSet(), hasLength(syms.length));
    });
  });

  group('default colours', () {
    // The ARGB values below are copied from WaypointCategory as it stood before
    // the icon and the category were separated. They are pinned rather than
    // read from the enum because they are not free: a waypoint saved under a
    // category and migrated to the matching glyph has to keep drawing in the
    // colour it has always drawn in, and the only thing standing between a
    // tidy-up of this palette and thirty repainted pins on someone's phone is
    // this test.
    const legacy = {
      'other': 0xFFB3261E,
      'stand': 0xFF6A4C1E,
      'blind': 0xFF4E342E,
      'camera': 0xFF1565C0,
      'sign': 0xFF6D4C41,
      'blood': 0xFF8E0000,
      'harvest': 0xFF37474F,
      'food': 0xFF558B2F,
      'water': 0xFF0277BD,
      'camp': 0xFF00695C,
      'parking': 0xFF455A64,
      'trailhead': 0xFF2E7D32,
      'fishing': 0xFF00838F,
      'viewpoint': 0xFF5E35B1,
      'hazard': 0xFFE65100,
      'trail': 0xFFAD1457,
      'route': 0xFF283593,
      'road': 0xFF3E2723,
      'portage': 0xFF827717,
      'boundary': 0xFF212121,
    };

    test('every glyph that was a category still carries its colour', () {
      for (final entry in legacy.entries) {
        expect(
          WaypointIcon.fromId(entry.key).colour.toARGB32(),
          entry.value,
          reason:
              '"${entry.key}" drew 0x${entry.value.toRadixString(16)} as a '
              'category and every waypoint already saved under it still does',
        );
      }
    });

    test('all twenty are accounted for', () {
      expect(legacy, hasLength(20));
      for (final id in legacy.keys) {
        expect(WaypointIcon.fromId(id).id, id, reason: id);
      }
    });

    // Colour is never the only thing telling two marks apart — the pictogram
    // always differs too — but two glyphs sharing an exact value wastes the
    // spread of colour this field exists to provide.
    test('no two glyphs share a colour', () {
      final colours = WaypointIcon.values
          .map((icon) => icon.colour.toARGB32())
          .toSet();
      expect(colours, hasLength(WaypointIcon.values.length));
    });
  });

  group('grouping, which only the picker reads', () {
    test('every icon is offered somewhere', () {
      final grouped = WaypointIcon.byGroup.values.expand((icons) => icons);
      expect(grouped, containsAll(WaypointIcon.values));
      expect(grouped, hasLength(WaypointIcon.values.length));
    });

    test('no group is present but empty', () {
      for (final entry in WaypointIcon.byGroup.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key.name);
      }
    });

    // The group says which section of the picker a glyph sits in and nothing
    // else. Nothing may filter what can be chosen by it: an angler marking a
    // stand and a hunter marking a dock are both making a legitimate choice,
    // and the old category list forbidding that is what this change undid.
    test('the hunting glyphs are not a separate vocabulary', () {
      expect(
        WaypointIcon.values.map((icon) => icon.id),
        containsAll(['stand', 'fishing', 'trailhead']),
      );
    });
  });
}
