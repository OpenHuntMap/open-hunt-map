import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/settings/display_settings.dart';
import 'package:open_woods_map/settings/marker_style.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';

/// A MapLibre `icon-offset` as logical pixels above the coordinate.
///
/// This is the arithmetic MapLibre performs: each component of `icon-offset` is
/// in the source image's own pixels and is multiplied by that layer's
/// `icon-size`, which the app sets so the 64 px image draws at [canvasDp]. Up
/// is negative in the style spec, so the sign flips here.
double _dpAbove(double offsetSourcePx, double canvasDp) =>
    -offsetSourcePx * canvasDp / sdfCanvasPx;

/// Where a point [sourceY] down the pin image ends up, in logical pixels above
/// the coordinate.
double _pinFeatureAbove(double sourceY, WaypointMarkerSize size) {
  final canvasDp = pinCanvasDp(size);
  final centreAbove = _dpAbove(pinImageOffset[1], canvasDp);
  return centreAbove - (sourceY - sdfCanvasPx / 2) * canvasDp / sdfCanvasPx;
}

/// WCAG relative contrast between two opaque colours.
double _contrast(Color a, Color b) {
  final high = math.max(a.computeLuminance(), b.computeLuminance());
  final low = math.min(a.computeLuminance(), b.computeLuminance());
  return (high + 0.05) / (low + 0.05);
}

void main() {
  // The generator measures the artwork it just rendered and writes the numbers
  // down. Nothing in the build makes the constants in marker_style.dart agree
  // with them, so this is what stops the two drifting: a regenerated pin whose
  // point has moved fails here rather than shipping every waypoint drawn a few
  // metres off the coordinate it was saved at.
  group('the pin the app measures is the pin that was generated', () {
    late Map<String, dynamic> manifest;
    late Map<String, dynamic> pin;

    setUpAll(() {
      manifest = jsonDecode(
        File('assets/waypoint_icons/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      pin = (manifest['backdrops'] as Map<String, dynamic>)['pin-backdrop']
          as Map<String, dynamic>;
    });

    test('the image exists and is the one the map asks for', () {
      expect(File('assets/waypoint_icons/pin-backdrop.png').existsSync(), isTrue);
      expect(pinBackdropAsset, 'assets/waypoint_icons/pin-backdrop.png');
    });

    test('the canvas and ink fraction are the generator\'s', () {
      expect((manifest['size'] as num).toDouble(), sdfCanvasPx);
      expect((manifest['ink_fraction'] as num).toDouble(), sdfInkFraction);
    });

    test('the point, the head and its width are where the app thinks', () {
      expect((pin['tip_y'] as num).toDouble(), closeTo(pinTipY, 0.001));
      expect(
        (pin['head_centre_y'] as num).toDouble(),
        closeTo(pinHeadCentreY, 0.001),
      );
      expect(
        (pin['head_diameter'] as num).toDouble(),
        closeTo(pinHeadDiameter, 0.001),
      );
    });

    // Material Icons has no solid pin: `place` is a teardrop with a circular
    // counter punched out of exactly the part the glyph has to read against.
    // The generator closes it, and if it ever stops the glyph would be sitting
    // over a hole with the basemap showing through.
    test('the counter is filled, because the glyph sits in it', () {
      expect(pin['holes_filled'], isTrue);
    });

    test('the pin is drawn from the same Material glyph as WaypointIcon.pin',
        () {
      expect(pin['codepoint'], WaypointIcon.pin.icon.codePoint);
    });
  });

  // The one thing on this feature that is a correctness question rather than a
  // matter of taste. A bare glyph is centred on its coordinate and a pin is
  // not: its point is. A waypoint that appears to move when a display setting
  // changes is the app lying about a coordinate, so the two styles have to
  // agree on where the spot is to the last decimal.
  group('the coordinate does not move when the style does', () {
    test('a bare glyph is centred on the coordinate', () {
      for (final size in WaypointMarkerSize.values) {
        expect(
          _dpAbove(
            glyphImageOffset(WaypointMarkerStyle.iconOnly)[1],
            glyphCanvasDp(size),
          ),
          0,
          reason: size.id,
        );
      }
    });

    test('the pin\'s point is on the coordinate, not its centre', () {
      for (final size in WaypointMarkerSize.values) {
        expect(
          _pinFeatureAbove(pinTipY, size),
          closeTo(0, 1e-9),
          reason: size.id,
        );
      }
    });

    // The lift cannot be done with `icon-anchor: bottom` instead. If it could,
    // this would be zero.
    test('the point is inside the canvas, so the anchor alone cannot do it',
        () {
      expect(pinTipY, lessThan(sdfCanvasPx));
      expect(
        _pinFeatureAbove(sdfCanvasPx, WaypointMarkerSize.standard),
        lessThan(0),
      );
    });

    test('the whole pin is above the coordinate it marks', () {
      for (final size in WaypointMarkerSize.values) {
        // The ink is centred in the canvas, so its top is as far above centre
        // as the point is below it.
        final inkTop = (sdfCanvasPx - sdfInkFraction * sdfCanvasPx) / 2;
        expect(_pinFeatureAbove(inkTop, size), greaterThan(0), reason: size.id);
      }
    });
  });

  group('the glyph inside the pin', () {
    test('sits at the centre of the pin\'s head at every size', () {
      for (final size in WaypointMarkerSize.values) {
        expect(
          _dpAbove(
            glyphImageOffset(WaypointMarkerStyle.pin)[1],
            glyphCanvasDp(size),
          ),
          closeTo(_pinFeatureAbove(pinHeadCentreY, size), 1e-9),
          reason: size.id,
        );
      }
    });

    // The pin is sized around the glyph rather than the glyph shrunk into the
    // pin. Turning pins on to make markers easier to see must not make the
    // pictogram smaller than it was, which is what fitting a glyph into
    // Material's rather thick-walled head would otherwise force.
    test('is not shrunk to fit, and the marker still grows', () {
      for (final size in WaypointMarkerSize.values) {
        final glyphInk = sdfInkFraction * glyphCanvasDp(size);
        final headDiameter =
            pinHeadDiameter / sdfCanvasPx * pinCanvasDp(size);
        expect(glyphInk / headDiameter, closeTo(0.66, 0.001), reason: size.id);
        // And the marker as a whole is far bigger than the bare glyph it
        // replaces, which is the entire point of offering the option.
        expect(
          sdfInkFraction * pinCanvasDp(size),
          greaterThan(glyphInk * 1.8),
          reason: size.id,
        );
      }
    });

    test('fits inside the head with a rim of pin left showing', () {
      for (final size in WaypointMarkerSize.values) {
        final glyphInk = sdfInkFraction * glyphCanvasDp(size);
        final headRadius =
            pinHeadDiameter / sdfCanvasPx * pinCanvasDp(size) / 2;
        // Worst case: a glyph whose ink fills its bounding square to the
        // corners, which is the furthest any of them reaches from the centre.
        final glyphCorner = glyphInk * math.sqrt2 / 2;
        expect(glyphCorner, lessThan(headRadius), reason: size.id);
      }
    });

    test('rides high enough that no part of it drops out of the head', () {
      for (final size in WaypointMarkerSize.values) {
        final glyphInk = sdfInkFraction * glyphCanvasDp(size);
        final headCentre = _pinFeatureAbove(pinHeadCentreY, size);
        expect(headCentre - glyphInk / 2, greaterThan(0), reason: size.id);
      }
    });
  });

  // Two of the ten colours a waypoint can be given are yellow and white. A
  // plain white glyph, which is what the request asked for, would make exactly
  // those waypoints unreadable while claiming to make them clearer.
  group('the glyph colour inside a pin', () {
    test('is white on a dark pin', () {
      expect(pinGlyphColour(WaypointColour.blue.value), Colors.white);
      expect(pinGlyphColour(WaypointColour.black.value), Colors.white);
    });

    test('is near-black on a light pin, not white', () {
      expect(pinGlyphColour(WaypointColour.yellow.value), isNot(Colors.white));
      expect(pinGlyphColour(WaypointColour.white.value), isNot(Colors.white));
    });

    // 3:1 is the WCAG minimum for a non-text graphic, which is what a
    // pictogram is.
    test('clears 3:1 against every colour a waypoint can be', () {
      for (final colour in WaypointColour.values) {
        expect(
          _contrast(colour.value, pinGlyphColour(colour.value)),
          greaterThan(3.0),
          reason: colour.id,
        );
      }
      for (final icon in WaypointIcon.values) {
        expect(
          _contrast(icon.colour, pinGlyphColour(icon.colour)),
          greaterThan(3.0),
          reason: icon.id,
        );
      }
    });

    test('is the hex MapLibre wants, for the colour it decided on', () {
      for (final colour in WaypointColour.values) {
        expect(
          pinGlyphHex(colour.value),
          hexColour(pinGlyphColour(colour.value)),
          reason: colour.id,
        );
      }
    });
  });

  group('the size steps', () {
    test('run smallest to largest, and standard is the map as it was', () {
      final multipliers = [
        for (final size in WaypointMarkerSize.values) size.multiplier,
      ];
      expect(multipliers, orderedEquals([...multipliers]..sort()));
      expect(WaypointMarkerSize.standard.multiplier, 1.0);
      expect(WaypointMarkerSize.fallback, WaypointMarkerSize.standard);
    });

    // Each step has to be visibly different from the one before or the control
    // is four ways of saying the same thing.
    test('are far enough apart to tell one from the next', () {
      final values = WaypointMarkerSize.values;
      for (var i = 1; i < values.length; i++) {
        final ratio = values[i].multiplier / values[i - 1].multiplier;
        expect(ratio, greaterThan(1.2), reason: values[i].id);
      }
    });

    test('scale everything a marker is made of by the same amount', () {
      for (final size in WaypointMarkerSize.values) {
        final factor = size.multiplier;
        expect(
          glyphCanvasDp(size),
          closeTo(glyphCanvasDp(WaypointMarkerSize.standard) * factor, 1e-9),
          reason: size.id,
        );
        expect(
          pinCanvasDp(size),
          closeTo(pinCanvasDp(WaypointMarkerSize.standard) * factor, 1e-9),
          reason: size.id,
        );
        expect(dotRadiusDp(size), closeTo(3.0 * factor, 1e-9), reason: size.id);
        expect(dotStrokeDp(size), closeTo(1.5 * factor, 1e-9), reason: size.id);
      }
    });

    // The same multiplier reaches the arrows along a track, so scaling
    // waypoints up does not leave the tracks decorated at the old size.
    test('scale the track direction markers too, spacing included', () {
      for (final size in WaypointMarkerSize.values) {
        expect(
          trackMarkerSizeFor(size),
          closeTo(trackMarkerSizeDp * size.multiplier, 1e-9),
          reason: size.id,
        );
        expect(
          trackMarkerSpacingFor(size),
          closeTo(trackMarkerSpacing * size.multiplier, 1e-9),
          reason: size.id,
        );
        expect(
          trackMarkerHaloFor(size),
          closeTo(trackMarkerHaloWidth * size.multiplier, 1e-9),
          reason: size.id,
        );
      }
    });

    // Wider markers at the old spacing close the gaps between themselves and
    // the line reads as a solid bar with no direction in it.
    test('keep the gap between track markers in proportion to their width',
        () {
      for (final size in WaypointMarkerSize.values) {
        expect(
          trackMarkerSpacingFor(size) / trackMarkerSizeFor(size),
          closeTo(trackMarkerSpacing / trackMarkerSizeDp, 1e-9),
          reason: size.id,
        );
      }
    });
  });

  group('ids, because they are written to preferences', () {
    test('every size round trips', () {
      for (final size in WaypointMarkerSize.values) {
        expect(WaypointMarkerSize.fromId(size.id), size, reason: size.id);
      }
    });

    test('every style round trips', () {
      for (final style in WaypointMarkerStyle.values) {
        expect(WaypointMarkerStyle.fromId(style.id), style, reason: style.id);
      }
    });

    test('no two share one', () {
      expect(
        WaypointMarkerSize.values.map((size) => size.id).toSet(),
        hasLength(WaypointMarkerSize.values.length),
      );
      expect(
        WaypointMarkerStyle.values.map((style) => style.id).toSet(),
        hasLength(WaypointMarkerStyle.values.length),
      );
    });

    // A preference written by a later build, or a hand-edited one. A display
    // setting is never worth failing a launch over.
    test('anything unrecognised falls back rather than throwing', () {
      expect(WaypointMarkerSize.fromId('enormous'), WaypointMarkerSize.standard);
      expect(WaypointMarkerSize.fromId(null), WaypointMarkerSize.standard);
      expect(
        WaypointMarkerStyle.fromId('teardrop'),
        WaypointMarkerStyle.iconOnly,
      );
      expect(WaypointMarkerStyle.fromId(null), WaypointMarkerStyle.iconOnly);
    });

    // Installing a build with this setting in it must not restyle a map
    // somebody already knows.
    test('the default style is what the map drew before the setting existed',
        () {
      expect(WaypointMarkerStyle.fallback, WaypointMarkerStyle.iconOnly);
      expect(glyphImageOffset(WaypointMarkerStyle.fallback), [0, 0]);
      expect(glyphCanvasDp(WaypointMarkerSize.fallback), 24.0);
    });
  });

  // What the offsets are for, asserted as an outcome rather than as arithmetic.
  // The constants were right and the map still drew the pin 117 physical pixels
  // high, because MapLibre multiplies icon-offset by icon-size and icon-size
  // carries the device pixel ratio, so the offset travelled that ratio too far.
  // Every screen ratio is checked because a bug that scales with the ratio looks
  // like nothing at all at 1.0.
  group('where the pin actually lands', () {
    for (final ratio in [1.0, 2.0, 2.625, 3.0, 3.5]) {
      for (final size in WaypointMarkerSize.values) {
        test('the point is on the coordinate at ${ratio}x, ${size.name}', () {
          final pinDp = pinCanvasDp(size);
          final landed = drawnOffsetFromAnchor(
            imagePixelY: pinTipY,
            iconOffset: iconOffsetFor(pinImageOffset, ratio),
            iconSize: iconSizeFor(pinDp, ratio),
            devicePixelRatio: ratio,
          );
          // Within a quarter of a logical pixel: closer than the screen can
          // draw, and far tighter than the metre or so this would mean on the
          // ground at any zoom someone navigates by.
          expect(landed, closeTo(0, 0.25));
        });

        test('the glyph sits in the head at ${ratio}x, ${size.name}', () {
          final glyphDp = glyphCanvasDp(size);
          final pinDp = pinCanvasDp(size);
          // The glyph's own centre, measured against the pin's head centre
          // expressed as a displacement from the coordinate the point is on.
          final glyphCentre = drawnOffsetFromAnchor(
            imagePixelY: sdfCanvasPx / 2,
            iconOffset: iconOffsetFor(
              glyphImageOffset(WaypointMarkerStyle.pin),
              ratio,
            ),
            iconSize: iconSizeFor(glyphDp, ratio),
            devicePixelRatio: ratio,
          );
          final headCentre =
              (pinHeadCentreY - pinTipY) / sdfCanvasPx * pinDp;
          expect(glyphCentre, closeTo(headCentre, 0.25));
        });
      }
    }
  });
}
