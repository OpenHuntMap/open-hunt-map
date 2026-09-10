import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/layer_panel.dart';
import 'package:open_woods_map/map/overlay_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('parseHexColor', () {
    test('parses the #RRGGBB form used in layer styles', () {
      expect(parseHexColor('#FFB300'), const Color(0xFFFFB300));
      expect(parseHexColor('FFB300'), const Color(0xFFFFB300));
      expect(parseHexColor('#00B8D4'), const Color(0xFF00B8D4));
    });

    test('falls back rather than throwing on malformed input', () {
      expect(parseHexColor(''), const Color(0xFF2E7D32));
      expect(parseHexColor('#GGGGGG'), const Color(0xFF2E7D32));
      expect(parseHexColor('#FFF'), const Color(0xFF2E7D32));
    });

    test('every palette entry round-trips to its own opaque colour', () {
      expect(OverlayController.palette, isNotEmpty);
      for (final hex in OverlayController.palette) {
        expect(hex, matches(RegExp(r'^#[0-9A-Fa-f]{6}$')));
        final expected = Color(
          0xFF000000 | int.parse(hex.substring(1), radix: 16),
        );
        expect(parseHexColor(hex), expected, reason: '$hex should parse exactly');
        expect(parseHexColor(hex).a, 1.0, reason: '$hex should be opaque');
      }
    });

    test('the palette has no duplicates', () {
      expect(
        OverlayController.palette.map((hex) => hex.toUpperCase()).toSet(),
        hasLength(OverlayController.palette.length),
      );
    });
  });

  group('layer defaults', () {
    test('every ordered layer has a default colour and a label', () {
      for (final id in OverlayController.layerOrder) {
        expect(
          OverlayController.defaultColorFor(id),
          matches(RegExp(r'^#[0-9A-Fa-f]{6}$')),
          reason: '$id needs a valid default colour',
        );
        expect(LayerPanel.labels[id], isNotNull, reason: '$id needs a label');
      }
    });

    test('no two layers share a default colour', () {
      final colours = OverlayController.layerOrder
          .map(OverlayController.defaultColorFor)
          .toList();
      expect(colours.toSet(), hasLength(colours.length));
    });

    test('crown land no longer defaults to green, so it reads on satellite', () {
      // The regression this guards: a green fill over green forest imagery was
      // effectively invisible.
      expect(OverlayController.defaultColorFor('crown_land'), '#FFB300');
    });

    test('occupied Crown land keeps clear of the colours that mean no hunting',
        () {
      // A lease is not a closure. Borrowing a closure's hue would say the one
      // thing this layer is careful not to say.
      final closures = ['game_preserve', 'federal_closure', 'defence_land']
          .map(OverlayController.defaultColorFor);
      expect(closures, isNot(contains(
        OverlayController.defaultColorFor('crown_disposition'),
      )));
    });
  });

  group('how much is known decides how much is drawn', () {
    test('Crown land with no policy is drawn fainter than Crown land with one',
        () {
      final policyFree =
          OverlayController.fillOpacityFor('crown_land', basis: 'tenure_only');
      final covered =
          OverlayController.fillOpacityFor('crown_land', basis: 'clupa');
      expect(policyFree, lessThan(covered),
          reason: 'half of Ontario\'s Crown land has no policy on it and must '
              'not be drawn as confidently as the half that does');
      expect(policyFree, greaterThan(0.0),
          reason: 'it is still Crown land and still has to be visible');
    });

    test('a parcel with no basis at all falls back to the layer opacity', () {
      expect(
        OverlayController.fillOpacityFor('crown_land'),
        OverlayController.fillOpacityFor('crown_land', basis: 'clupa'),
      );
    });

    test('layers that do not vary report one opacity whatever the basis', () {
      expect(
        OverlayController.fillOpacityFor('parks', basis: 'tenure_only'),
        OverlayController.fillOpacityFor('parks', basis: 'anything'),
      );
    });
  });

  group('colour overrides', () {
    test('start empty and report the default', () {
      final controller = OverlayController();
      expect(controller.isCustomColor('crown_land'), isFalse);
      expect(
        controller.colorFor('crown_land'),
        OverlayController.defaultColorFor('crown_land'),
      );
    });

    test('setColor overrides, and null restores the default', () async {
      final controller = OverlayController();

      await controller.setColor('crown_land', '#C2185B');
      expect(controller.colorFor('crown_land'), '#C2185B');
      expect(controller.isCustomColor('crown_land'), isTrue);

      await controller.setColor('crown_land', null);
      expect(controller.isCustomColor('crown_land'), isFalse);
      expect(
        controller.colorFor('crown_land'),
        OverlayController.defaultColorFor('crown_land'),
      );
    });

    test('overrides survive a reload through preferences', () async {
      final first = OverlayController();
      await first.setColor('parks', '#FAFAFA');
      await first.setColor('wmu', '#D50000');

      final second = OverlayController();
      await second.loadPreferences();

      expect(second.colorFor('parks'), '#FAFAFA');
      expect(second.colorFor('wmu'), '#D50000');
      expect(second.isCustomColor('municipalities'), isFalse);
    });

    test('clearing the last override wipes the stored preference', () async {
      final controller = OverlayController();
      await controller.setColor('parks', '#FAFAFA');
      await controller.setColor('parks', null);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('overlay.colors'), isNull);
    });

    test('ignores unknown layer ids and corrupt stored preferences', () async {
      SharedPreferences.setMockInitialValues({
        'overlay.colors': '{"not_a_layer":"#FFFFFF"}',
      });
      final controller = OverlayController();
      await controller.loadPreferences();
      expect(controller.isCustomColor('not_a_layer'), isFalse);

      SharedPreferences.setMockInitialValues({'overlay.colors': 'not json'});
      final resilient = OverlayController();
      await resilient.loadPreferences();
      expect(resilient.colorFor('crown_land'), '#FFB300');
    });

    test('notifies listeners so the map and panel repaint', () async {
      final controller = OverlayController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setColor('crown_land', '#6A1B9A');
      expect(notifications, 1);
    });
  });
}
