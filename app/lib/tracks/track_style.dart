import 'package:flutter/material.dart';

import '../waypoints/waypoint_colour.dart';
import '../waypoints/waypoint_icon.dart';

/// How a track is drawn: the stroke of its line, the marker repeated along it,
/// and the colours both of those need.

/// The stroke pattern of a track's line.
///
/// Drawn as one map layer per entry, each filtered to the tracks that chose it,
/// rather than one layer with a data-driven `line-dasharray`. MapLibre documents
/// that property as data-driven on the web only, so a single layer cannot dash
/// some tracks and leave others solid on Android or iOS. Three layers is the
/// entire cost of having the choice at all, and it is why this is a short fixed
/// list rather than a dash editor.
enum TrackStroke {
  solid(id: 'solid', label: 'Solid', dash: null, cap: 'round'),

  /// Dash lengths are in line widths, as the style spec defines them, so the
  /// pattern keeps its proportions if the line width ever changes. Butt caps
  /// because round ones add half a line width to both ends of every dash, which
  /// at this width closes the gaps up until it reads as solid.
  dashed(id: 'dashed', label: 'Dashed', dash: [2.2, 1.8], cap: 'butt'),

  /// A dash far shorter than the gap, under a round cap, is what draws a dot.
  /// Given a small positive length rather than zero because a zero-length dash
  /// is not reliably rendered.
  dotted(id: 'dotted', label: 'Dotted', dash: [0.1, 2.0], cap: 'round');

  const TrackStroke({
    required this.id,
    required this.label,
    required this.dash,
    required this.cap,
  });

  /// Stored in the waypoint file and in exported GeoJSON, so it must stay
  /// stable across releases even if [label] is reworded.
  final String id;
  final String label;

  /// Null for a continuous line. MapLibre rejects an empty array, so absence has
  /// to be absence rather than `[]`.
  final List<double>? dash;

  /// `line-cap`, which is part of the pattern rather than a separate choice: a
  /// dotted line needs round caps to be dots at all.
  final String cap;

  static const fallback = TrackStroke.solid;

  /// Unknown ids fall back rather than throwing, because this reads files
  /// written by other builds and by hand.
  static TrackStroke fromId(String? id) => values.firstWhere(
        (stroke) => stroke.id == id,
        orElse: () => fallback,
      );
}

/// The marker repeated along a track to show which way it runs.
///
/// Unlike the stroke these all share one map layer, because `icon-image` *is*
/// data-driven on mobile. Adding a shape therefore costs a glyph and nothing
/// else.
enum TrackMarker {
  none(id: 'none', label: 'None', icon: null, image: '', asset: null),
  arrow(
    id: 'arrow',
    label: 'Arrows',
    icon: Icons.play_arrow,
    image: 'owm-track-arrow',
    asset: 'assets/waypoint_icons/track-arrow.png',
  ),
  chevron(
    id: 'chevron',
    label: 'Chevrons',
    icon: Icons.chevron_right,
    image: 'owm-track-chevron',
    asset: 'assets/waypoint_icons/track-chevron.png',
  ),
  doubleChevron(
    id: 'double',
    label: 'Double chevrons',
    icon: Icons.double_arrow,
    image: 'owm-track-chevron-double',
    asset: 'assets/waypoint_icons/track-chevron-double.png',
  );

  const TrackMarker({
    required this.id,
    required this.label,
    required this.icon,
    required this.image,
    required this.asset,
  });

  final String id;
  final String label;

  /// The same glyph as [asset], for drawing a preview in Flutter. Both come out
  /// of the Material Icons font at the same codepoint — a test asserts that, so
  /// the preview cannot start showing a shape the map does not draw.
  final IconData? icon;

  /// The MapLibre image name. Empty for [none], which is also what the marker
  /// layer's filter tests: a feature with no marker is excluded rather than
  /// given an `icon-image` that does not resolve, because MapLibre draws nothing
  /// and reports nothing in that case and it is indistinguishable from a bug.
  final String image;

  final String? asset;

  bool get draws => image.isNotEmpty;

  static const fallback = TrackMarker.arrow;

  /// Arrows are the default: a track without them says where it went but not
  /// which way, and which way is the point of following one back out.
  static TrackMarker fromId(String? id) => values.firstWhere(
        (marker) => marker.id == id,
        orElse: () => fallback,
      );

  /// Every marker that has a glyph to register with the map.
  static Iterable<TrackMarker> get drawn =>
      values.where((marker) => marker.draws);
}

/// Markers sit on top of the line, so they cannot be the line's colour.
///
/// Drawing them in the track colour makes them vanish into it — the whole point
/// of the marker is lost on exactly the tracks whose colour the user chose most
/// deliberately. White reads on everything except a white or yellow track, so
/// the choice is made per track from its own luminance rather than fixed.
Color markerColourFor(Color track) =>
    ThemeData.estimateBrightnessForColor(track) == Brightness.dark
    ? Colors.white
    : const Color(0xFF212121);

/// [markerColourFor] as MapLibre wants it.
///
/// Separate from the [Color] version, and named for where it goes, because these
/// end up in a GeoJSON feature's properties and those cross a method channel: a
/// `Color` put there throws "Invalid argument: Instance of 'Color'" from deep
/// inside the codec, which names neither the property nor the layer.
String markerHexFor(Color track) => hexColour(markerColourFor(track));

/// Marker width in logical pixels.
///
/// Twice the line width, which reads as a mark set into the line rather than
/// stuck on top of it. At 13 it burst visibly out of both sides of the track on
/// a device.
const trackMarkerSizeDp = 10.0;

/// Screen distance between markers, in pixels.
///
/// MapLibre's default of 250 put one marker on a two-kilometre track and none at
/// all on a short one, and a track with no marker reads as having no direction
/// rather than as being short. Symbols are laid out at whole zoom levels and then
/// scaled, so the spacing actually seen varies either side of this.
const trackMarkerSpacing = 50.0;

/// Marker halo width in logical pixels.
///
/// Drawn in the track's own colour, so a marker reads as a hole punched in the
/// line rather than a mark beside it. It is doing real work on a dashed or
/// dotted line, where a marker can land in a gap: without it the marker's
/// contrast colour sits on the bare basemap, which is the one place it has
/// nothing to contrast against.
const trackMarkerHaloWidth = 1.2;

/// Line width in logical pixels for a saved track.
const trackLineWidth = 5.0;

/// How much larger than the map a [TrackPreview] draws everything.
///
/// Applied uniformly to the line width, the dash lengths, the marker size and
/// the spacing between markers, so the proportions the user is choosing between
/// stay true and only the whole thing is bigger. At 1.0 a marker is eight
/// logical pixels across, where a chevron and a double chevron are the same
/// smudge and the picker would be no help at all.
const trackPreviewScale = 1.8;

/// The colour a track's line is drawn in: the override if the user set one,
/// otherwise the colour its glyph carries.
String trackLineColour(WaypointIcon icon, WaypointColour? colour) =>
    hexColour(colour?.value ?? icon.colour);
