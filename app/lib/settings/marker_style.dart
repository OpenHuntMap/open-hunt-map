import 'package:flutter/material.dart';

import '../tracks/track_style.dart';
import 'display_settings.dart';

/// How the map draws a waypoint marker, given the display settings.
///
/// Everything here is arithmetic over the generated images, kept out of the map
/// shell so it can be asserted. The numbers it works from are measurements of
/// real artwork rather than choices: they are written into
/// `assets/waypoint_icons/manifest.json` by
/// `tools/icons/build_waypoint_icons.py`, and a test reads them back and fails
/// if the constants below have drifted from the images that shipped.

/// The MapLibre image name and asset for the pin the glyph sits in.
const pinBackdropImage = 'owm-wp-pin-backdrop';
const pinBackdropAsset = 'assets/waypoint_icons/pin-backdrop.png';

/// Every generated image is this many pixels square.
const sdfCanvasPx = 64.0;

/// How much of that canvas the glyph's longest side fills. The rest is margin
/// for the distance field's spread and for the halo the map draws outside it.
const sdfInkFraction = 0.8;

/// Where the pin's point sits in its own image, measured down from the top.
///
/// Not 64: the distance field needs margin all round and the generator asserts
/// the outer two pixels stay empty, so the point is inside the canvas and
/// `icon-anchor: bottom` would hang the pin six pixels above the coordinate.
const pinTipY = 57.5;

/// Where the centre of the pin's head sits in its own image.
///
/// Read from the counter Material punches out of the head, which is concentric
/// with it; the generator fails if it ever stops being.
const pinHeadCentreY = 24.375;

/// The head's outer width at its own centre line.
const pinHeadDiameter = 36.0;

/// How much of the head's width the glyph inside it may take.
///
/// A glyph's ink is a square at worst, so two thirds of the diameter puts its
/// corners at 0.47 diameters from the head's centre against a radius of 0.5 —
/// a thin rim of pin left showing all the way round. Most Material glyphs leave
/// their own corners emptier than a square, so the rim reads wider than the
/// arithmetic promises.
const _glyphInHead = 0.66;

/// The pin's canvas as a multiple of the glyph's, which is what converts a
/// distance measured in one image's pixels into the other's.
///
/// A constant, and that matters: both canvases scale by the same multiplier, so
/// the ratio — and therefore the offset that lifts the glyph into the pin's
/// head — is the same at every size step.
const _pinPerGlyphCanvas =
    sdfInkFraction * sdfCanvasPx / (_glyphInHead * pinHeadDiameter);

/// The glyph's canvas in logical pixels.
///
/// 24 dp is what a bare glyph has always been drawn at, and it is deliberately
/// the same in both marker styles: the pin is sized around the glyph rather
/// than the glyph shrunk to fit inside the pin. Shrinking it would make the
/// pictogram harder to read at the moment the user asked for the marker to be
/// easier to see.
double glyphCanvasDp(WaypointMarkerSize size) => 24.0 * size.multiplier;

/// The pin's canvas in logical pixels — the whole 64 px image, of which the
/// teardrop itself is [sdfInkFraction].
double pinCanvasDp(WaypointMarkerSize size) =>
    glyphCanvasDp(size) * _pinPerGlyphCanvas;

/// `icon-offset` for the pin layer, in the pin image's own pixels.
///
/// The point of a pin marks the spot, where a bare glyph is centred on it. The
/// image is centred on the coordinate by default, so it has to ride up by the
/// distance from its centre down to its point, and then the point is on the
/// coordinate exactly. Getting this wrong does not look wrong — it looks like a
/// waypoint tens of metres from where it was saved, which is the app lying
/// about a coordinate.
const pinImageOffset = <double>[0, -(pinTipY - sdfCanvasPx / 2)];

/// `icon-offset` for the glyph layer, in the glyph image's own pixels.
///
/// Zero for a bare glyph: its centre is the coordinate, which is what it has
/// always been. Inside a pin it rises to the head's centre, which is
/// [pinTipY] − [pinHeadCentreY] above the point in *pin* pixels. MapLibre
/// scales each layer's offset by that layer's own `icon-size`, so crossing from
/// one image's pixels to the other's is the ratio of their drawn sizes.
List<double> glyphImageOffset(WaypointMarkerStyle style) => switch (style) {
      WaypointMarkerStyle.iconOnly => const [0, 0],
      WaypointMarkerStyle.pin => const [
          0,
          -(pinTipY - pinHeadCentreY) * _pinPerGlyphCanvas,
        ],
    };

/// Radius of the circle drawn at the coordinate under every marker.
///
/// It scales with the rest because on a software GL stack, which renders no
/// symbol layers at all, this circle *is* the marker — Android emulators are a
/// supported target and BlueStacks is one of them. A size setting that left
/// those devices alone would do nothing on the one where the marker is already
/// smallest.
double dotRadiusDp(WaypointMarkerSize size) => 3.0 * size.multiplier;

/// Stroke around that circle, scaled with it so it stays an outline rather than
/// swallowing the fill.
double dotStrokeDp(WaypointMarkerSize size) => 1.5 * size.multiplier;

/// The ink a glyph draws in when it sits inside a coloured pin.
///
/// Not the plain white the request suggested. Two of the ten colours a waypoint
/// can be given are yellow and white, and a white glyph on either of those is
/// not a glyph at all — the setting would make exactly those waypoints
/// unreadable while claiming to make them clearer. So white on a dark pin and
/// near-black on a light one, decided from the pin's own luminance.
///
/// It is the same rule, and the same function, as the markers repeated along a
/// track, which sit on a colour the user chose for the same reason and are
/// solving the identical problem.
Color pinGlyphColour(Color pin) => markerColourFor(pin);

/// [pinGlyphColour] as a MapLibre `icon-color`.
///
/// Per feature rather than a constant on the layer, because which of the two
/// inks reads depends on the colour of the pin it is sitting in.
String pinGlyphHex(Color pin) => markerHexFor(pin);

/// Track direction marker width, scaled with the waypoint markers.
///
/// The same multiplier deliberately reaches both. A user who scales waypoints
/// up because they cannot see them is not asking for their tracks to keep
/// hairline decoration, and two marker sets on one screen at different scales
/// reads as a bug rather than a choice.
double trackMarkerSizeFor(WaypointMarkerSize size) =>
    trackMarkerSizeDp * size.multiplier;

/// Screen distance between track direction markers, scaled with their width.
///
/// Scaled, not fixed. Markers half again as wide at the same spacing close the
/// gaps between themselves and the line reads as a solid bar with no direction
/// in it, which is the one thing the markers exist to say.
double trackMarkerSpacingFor(WaypointMarkerSize size) =>
    trackMarkerSpacing * size.multiplier;

/// Halo around a track direction marker, scaled so it stays the hole punched
/// in the line rather than a ring beside it.
double trackMarkerHaloFor(WaypointMarkerSize size) =>
    trackMarkerHaloWidth * size.multiplier;
