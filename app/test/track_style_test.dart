import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';

void main() {
  group('the direction arrow image', () {
    late Map<String, dynamic> manifest;

    setUpAll(() {
      manifest =
          jsonDecode(
                File('assets/waypoint_icons/manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    test('is generated and bundled', () {
      // A symbol layer whose icon-image is missing draws nothing at all and
      // reports nothing about why, so the arrow going absent would look like
      // MapLibre ignoring symbol-placement rather than a missing file.
      expect(
        (manifest['extras'] as Map<String, dynamic>).containsKey('track-arrow'),
        isTrue,
        reason: 'Run python tools/icons/build_waypoint_icons.py',
      );
      expect(File('assets/waypoint_icons/track-arrow.png').existsSync(), isTrue);
    });

    test('the asset path the app loads is the file that exists', () {
      // trackArrowAsset is what rootBundle.load is given, and pubspec bundles
      // the directory, so a rename here fails at runtime rather than at build.
      expect(trackArrowAsset, 'assets/waypoint_icons/track-arrow.png');
      expect(File(trackArrowAsset).existsSync(), isTrue);
    });

    test('does not collide with a category image name', () {
      final names = WaypointCategory.values.map((c) => c.iconImage).toSet();
      expect(names, isNot(contains(trackArrowImage)));
    });
  });

  group('the arrow colour', () {
    test('is light on a dark track and dark on a light one', () {
      expect(arrowColourFor(const Color(0xFF212121)), '#FFFFFF');
      expect(arrowColourFor(const Color(0xFFFAFAFA)), '#212121');
    });

    // These two are the reason the colour is computed rather than fixed white:
    // a white arrow on a white or yellow track is an invisible arrow, and those
    // are colours a user picks deliberately for contrast against dark ground.
    test('stays visible on the white and yellow track colours', () {
      expect(arrowColourFor(WaypointColour.white.value), '#212121');
      expect(arrowColourFor(WaypointColour.yellow.value), '#212121');
    });

    test('every track colour gets an arrow that is not its own colour', () {
      for (final colour in WaypointColour.values) {
        expect(
          arrowColourFor(colour.value),
          isNot(hexColour(colour.value)),
          reason: '${colour.id} arrows would vanish into the line',
        );
      }
    });

    test('every category colour gets an arrow that is not its own colour', () {
      for (final category in WaypointCategory.values) {
        expect(
          arrowColourFor(category.colour),
          isNot(hexColour(category.colour)),
          reason: '${category.id} arrows would vanish into the line',
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
