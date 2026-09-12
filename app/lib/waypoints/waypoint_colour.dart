import 'package:flutter/material.dart';

/// `#RRGGBB`, which is what MapLibre's `icon-color` wants.
String hexColour(Color colour) =>
    '#${(colour.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// `aabbggrr` — KML's byte order, which is reversed from everyone else's and is
/// a standing source of blue waypoints that were meant to be red.
String kmlColour(Color colour) {
  final rgb = colour.toARGB32() & 0xFFFFFF;
  String two(int value) => value.toRadixString(16).padLeft(2, '0');
  return 'ff${two(rgb & 0xFF)}${two((rgb >> 8) & 0xFF)}${two((rgb >> 16) & 0xFF)}';
}

/// The colours a waypoint can be given, as the user sees them.
///
/// A short list on purpose. These have to stay apart from each other on a
/// satellite basemap and on a green land-cover one, and a free colour picker
/// mostly produces choices that fail on one or the other.
enum WaypointColour {
  red(id: 'red', label: 'Red', value: Color(0xFFB3261E)),
  orange(id: 'orange', label: 'Orange', value: Color(0xFFE65100)),
  yellow(id: 'yellow', label: 'Yellow', value: Color(0xFFF9A825)),
  green(id: 'green', label: 'Green', value: Color(0xFF2E7D32)),
  teal(id: 'teal', label: 'Teal', value: Color(0xFF00838F)),
  blue(id: 'blue', label: 'Blue', value: Color(0xFF1565C0)),
  purple(id: 'purple', label: 'Purple', value: Color(0xFF6A1B9A)),
  brown(id: 'brown', label: 'Brown', value: Color(0xFF5D4037)),
  black(id: 'black', label: 'Black', value: Color(0xFF212121)),
  white(id: 'white', label: 'White', value: Color(0xFFFAFAFA));

  const WaypointColour({
    required this.id,
    required this.label,
    required this.value,
  });

  final String id;
  final String label;
  final Color value;

  static WaypointColour? fromId(String? id) {
    if (id == null) return null;
    final wanted = id.trim().toLowerCase();
    for (final colour in values) {
      if (colour.id == wanted) return colour;
    }
    return null;
  }
}
