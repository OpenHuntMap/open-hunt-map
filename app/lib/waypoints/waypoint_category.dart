import 'package:flutter/material.dart';

/// What a waypoint is, and how that survives leaving this app.
///
/// Every app worth exporting to organises waypoints under a single parent — a
/// CalTopo folder, a Garmin Explore collection, an onX folder — so the category
/// here is single-valued and required. Tags are the loose, many-valued layer on
/// top, and they are best-effort on export because no interchange format has a
/// dependable place to put them.
///
/// Three separate things carry the meaning out of the app, in descending order
/// of how well they travel:
///
/// - [id] goes into GPX `<type>` and a KML folder name, and comes back on
///   import. This is the lossless path, and the only one that round trips.
/// - [garminSym] goes into GPX `<sym>`, which is what makes the icon appear on a
///   Garmin unit. Null where Garmin has no matching symbol; see below.
/// - [colour] is a hint and nothing more. Garmin has no waypoint colour field at
///   all, and onX discards colour, icons and notes on import. So colour must
///   never be the only thing distinguishing two categories — the glyph always
///   differs too, and that is deliberate.
enum WaypointCategory {
  // Garmin symbol names below are the display names from GPSBabel's
  // garmin_icon_tables.h, which is the reference the GPX ecosystem shares. They
  // are spelled exactly as Garmin spells them because a near miss silently
  // falls back to a default pin. Where Garmin has nothing that means the right
  // thing, garminSym is null and `<sym>` is omitted rather than filled with
  // something misleading: a wrong icon on the unit is worse than a default one.
  other(
    id: 'other',
    label: 'Other',
    icon: Icons.place,
    garminSym: 'Waypoint',
    colour: Color(0xFFB3261E),
  ),
  stand(
    id: 'stand',
    label: 'Tree stand',
    icon: Icons.chair_alt,
    garminSym: 'Tree Stand',
    colour: Color(0xFF6A4C1E),
  ),
  blind(
    id: 'blind',
    label: 'Blind',
    icon: Icons.night_shelter,
    garminSym: 'Blind',
    colour: Color(0xFF4E342E),
  ),
  camera(
    id: 'camera',
    label: 'Trail camera',
    icon: Icons.photo_camera,
    // Garmin's vocabulary predates trail cameras and has no symbol for one.
    garminSym: null,
    colour: Color(0xFF1565C0),
  ),
  sign(
    id: 'sign',
    label: 'Animal sign',
    icon: Icons.pets,
    garminSym: 'Animal Tracks',
    colour: Color(0xFF6D4C41),
  ),
  blood(
    id: 'blood',
    label: 'Blood trail',
    icon: Icons.bloodtype,
    garminSym: 'Blood Trail',
    colour: Color(0xFF8E0000),
  ),
  harvest(
    id: 'harvest',
    label: 'Harvest',
    icon: Icons.flag,
    // Garmin has no generic "harvest"; Big Game is the closest real symbol and
    // is what a hunting unit shows for a taken animal.
    garminSym: 'Big Game',
    colour: Color(0xFF37474F),
  ),
  food(
    id: 'food',
    label: 'Food source',
    icon: Icons.grass,
    garminSym: 'Food Source',
    colour: Color(0xFF558B2F),
  ),
  water(
    id: 'water',
    label: 'Water source',
    icon: Icons.water_drop,
    garminSym: 'Water Source',
    colour: Color(0xFF0277BD),
  ),
  camp(
    id: 'camp',
    label: 'Camp',
    icon: Icons.cabin,
    garminSym: 'Campground',
    colour: Color(0xFF00695C),
  ),
  parking(
    id: 'parking',
    label: 'Parking or access',
    icon: Icons.local_parking,
    garminSym: 'Parking Area',
    colour: Color(0xFF455A64),
  ),
  trailhead(
    id: 'trailhead',
    label: 'Trailhead',
    icon: Icons.hiking,
    garminSym: 'Trail Head',
    colour: Color(0xFF2E7D32),
  ),
  fishing(
    id: 'fishing',
    label: 'Fishing spot',
    icon: Icons.phishing,
    garminSym: 'Fishing Area',
    colour: Color(0xFF00838F),
  ),
  viewpoint(
    id: 'viewpoint',
    label: 'Viewpoint',
    icon: Icons.landscape,
    garminSym: 'Summit',
    colour: Color(0xFF5E35B1),
  ),
  hazard(
    id: 'hazard',
    label: 'Hazard',
    icon: Icons.warning,
    garminSym: 'Skull and Crossbones',
    colour: Color(0xFFE65100),
  );

  const WaypointCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.garminSym,
    required this.colour,
  });

  /// Stable across releases: it is written into saved files and exports, so
  /// renaming one silently reclassifies every waypoint already saved under it.
  final String id;

  final String label;

  /// Drawn in the app's own lists. The map draws the same glyph as an SDF image
  /// generated from this codepoint by `tools/icons/build_waypoint_icons.py`,
  /// and a test asserts the two have not drifted apart.
  final IconData icon;

  /// The exact Garmin symbol display name, or null where none fits.
  final String? garminSym;

  /// The default colour. The user can override it per waypoint.
  final Color colour;

  /// The MapLibre image name for this category's SDF glyph.
  String get iconImage => 'owm-wp-$id';

  /// Resolves a stored or imported id, falling back to [other].
  ///
  /// Unknown ids are expected rather than exceptional: a file exported by a
  /// later build, or by another app that put something else in `<type>`. Losing
  /// the category is acceptable there. Losing the waypoint is not.
  static WaypointCategory fromId(String? id) {
    if (id == null) return WaypointCategory.other;
    final wanted = id.trim().toLowerCase();
    for (final category in values) {
      if (category.id == wanted) return category;
    }
    // Garmin round trips `<sym>` more reliably than `<type>` through some
    // tools, so a file that lost its type can still be placed by its symbol.
    for (final category in values) {
      if (category.garminSym?.toLowerCase() == wanted) return category;
    }
    // KML folder names are the human label, because that is what makes a folder
    // worth having in Google Earth. A file whose ExtendedData was stripped can
    // still be placed from the folder it came out of.
    for (final category in values) {
      if (category.label.toLowerCase() == wanted) return category;
    }
    return WaypointCategory.other;
  }
}

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
