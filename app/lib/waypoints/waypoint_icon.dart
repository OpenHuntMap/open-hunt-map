import 'package:flutter/material.dart';

/// Which part of the picker a glyph sits under.
///
/// Grouping only, never meaning: an angler is free to mark a stand and a hunter
/// a dock. The sections exist because a flat wall of thirty pictograms is
/// unreadable, not because the app has an opinion about who marks what.
enum WaypointIconGroup {
  general(label: 'General'),
  hunting(label: 'Hunting'),
  fishing(label: 'Fishing and water'),
  travel(label: 'Getting there'),
  hazards(label: 'Hazards'),
  lines(label: 'Lines and routes');

  const WaypointIconGroup({required this.label});

  final String label;
}

/// The glyph a waypoint draws as, in this app's lists and on the map.
///
/// This is a picture and nothing else. It says nothing about what the waypoint
/// *is* — tags do that — which is why there is no rule against putting the fish
/// on a stand or the chair on a portage.
///
/// The one thing here that is not free choice is [garminSym]. Garmin units draw
/// an icon only for symbol names from their own fixed table, so this is the one
/// place a closed vocabulary is unavoidable, and it is why the enum exists at
/// all rather than the icon being a free codepoint.
enum WaypointIcon {
  // Garmin symbol names below are the display names from GPSBabel's
  // garmin_icon_tables.h, which is the reference the GPX ecosystem shares. They
  // are spelled exactly as Garmin spells them because a near miss is silently
  // ignored by the unit and falls back to a default pin. Where Garmin has
  // nothing that means the right thing, garminSym is null and `<sym>` is
  // omitted rather than filled with something misleading: a wrong icon on the
  // unit is worse than a default one.
  //
  // Every glyph added since the icon stopped being a category carries null for
  // the same reason. Guessing at a plausible Garmin name — "Boat Ramp",
  // "Geocache" — would be inventing a fact about someone else's device.
  //
  // The colours on the first twenty are the ones their categories carried when
  // the icon and the category were one field, kept to the exact ARGB value so
  // that a waypoint saved before the split draws in the colour it has always
  // drawn in. A test pins them. Changing one repaints waypoints already on
  // someone's phone, which is a migration in everything but name.
  pin(
    // Stays 'other' because this id is written into the waypoint file and is
    // also the SDF asset's filename. Renaming it would silently un-icon every
    // waypoint already saved and orphan assets/waypoint_icons/other.png.
    id: 'other',
    label: 'Pin',
    icon: Icons.place,
    garminSym: 'Waypoint',
    colour: Color(0xFFB3261E),
  ),
  viewpoint(
    id: 'viewpoint',
    label: 'Viewpoint',
    icon: Icons.landscape,
    garminSym: 'Summit',
    colour: Color(0xFF5E35B1),
  ),
  camp(
    id: 'camp',
    label: 'Camp',
    icon: Icons.cabin,
    garminSym: 'Campground',
    colour: Color(0xFF00695C),
  ),
  tent(
    id: 'tent',
    label: 'Tent',
    icon: Icons.festival,
    garminSym: null,
    // A shade off camp, close enough to read as the same kind of thing at a
    // glance and far enough apart to tell two marks on a lake apart.
    colour: Color(0xFF00796B),
  ),
  // Material's glyph is a kettle grill with smoke rising, so the label says
  // grill as well as fire rather than promising a stone ring.
  firepit(
    id: 'firepit',
    label: 'Fire or grill',
    icon: Icons.outdoor_grill,
    garminSym: null,
    // Ember, not hazard orange: a fire ring is a place you are glad to find,
    // and the two should not read as the same warning.
    colour: Color(0xFFBF360C),
  ),
  water(
    id: 'water',
    label: 'Water source',
    icon: Icons.water_drop,
    garminSym: 'Water Source',
    colour: Color(0xFF0277BD),
  ),
  cache(
    id: 'cache',
    label: 'Cache',
    icon: Icons.inventory_2,
    garminSym: null,
    // Deliberately neutral. A cache is whatever the user left there, and no
    // hue in this set means "supplies" without borrowing someone else's
    // meaning.
    colour: Color(0xFF616161),
  ),
  // A leaf, labelled for what it is used for. Material Icons has no mushroom
  // and no berry, and the nearest glyphs are a flower and a spa symbol, so one
  // honest general-purpose pictogram beats two that draw the wrong plant.
  foraging(
    id: 'foraging',
    label: 'Foraging',
    icon: Icons.eco,
    garminSym: null,
    // Green, alongside food source, because both mark something growing.
    colour: Color(0xFF33691E),
  ),

  stand(
    id: 'stand',
    label: 'Tree stand',
    icon: Icons.chair_alt,
    garminSym: 'Tree Stand',
    colour: Color(0xFF6A4C1E),
    group: WaypointIconGroup.hunting,
  ),
  blind(
    id: 'blind',
    label: 'Blind',
    icon: Icons.night_shelter,
    garminSym: 'Blind',
    colour: Color(0xFF4E342E),
    group: WaypointIconGroup.hunting,
  ),
  camera(
    id: 'camera',
    label: 'Trail camera',
    icon: Icons.photo_camera,
    // Garmin's vocabulary predates trail cameras and has no symbol for one.
    garminSym: null,
    colour: Color(0xFF1565C0),
    group: WaypointIconGroup.hunting,
  ),
  sign(
    id: 'sign',
    label: 'Animal sign',
    icon: Icons.pets,
    garminSym: 'Animal Tracks',
    colour: Color(0xFF6D4C41),
    group: WaypointIconGroup.hunting,
  ),
  blood(
    id: 'blood',
    label: 'Blood trail',
    icon: Icons.bloodtype,
    garminSym: 'Blood Trail',
    colour: Color(0xFF8E0000),
    group: WaypointIconGroup.hunting,
  ),
  harvest(
    id: 'harvest',
    label: 'Harvest',
    icon: Icons.flag,
    // Garmin has no generic "harvest"; Big Game is the closest real symbol and
    // is what a hunting unit shows for a taken animal.
    garminSym: 'Big Game',
    colour: Color(0xFF37474F),
    group: WaypointIconGroup.hunting,
  ),
  food(
    id: 'food',
    label: 'Food source',
    icon: Icons.grass,
    garminSym: 'Food Source',
    colour: Color(0xFF558B2F),
    group: WaypointIconGroup.hunting,
  ),

  fishing(
    id: 'fishing',
    label: 'Fishing spot',
    icon: Icons.phishing,
    garminSym: 'Fishing Area',
    colour: Color(0xFF00838F),
    group: WaypointIconGroup.fishing,
  ),
  dock(
    id: 'dock',
    label: 'Dock or mooring',
    icon: Icons.anchor,
    garminSym: null,
    // The deep end of water source's blue: a dock is a place on the water.
    colour: Color(0xFF01579B),
    group: WaypointIconGroup.fishing,
  ),
  boatLaunch(
    id: 'boat-launch',
    label: 'Boat launch',
    icon: Icons.directions_boat,
    garminSym: null,
    // Beside fishing's cyan, since a launch is usually how the fishing starts.
    colour: Color(0xFF0097A7),
    group: WaypointIconGroup.fishing,
  ),

  parking(
    id: 'parking',
    label: 'Parking or access',
    icon: Icons.local_parking,
    garminSym: 'Parking Area',
    colour: Color(0xFF455A64),
    group: WaypointIconGroup.travel,
  ),
  trailhead(
    id: 'trailhead',
    label: 'Trailhead',
    icon: Icons.hiking,
    garminSym: 'Trail Head',
    colour: Color(0xFF2E7D32),
    group: WaypointIconGroup.travel,
  ),
  signpost(
    id: 'signpost',
    label: 'Signpost or junction',
    icon: Icons.signpost,
    garminSym: null,
    // A shade off trailhead, because a junction is the same errand as a
    // trailhead once you are already walking.
    colour: Color(0xFF388E3C),
    group: WaypointIconGroup.travel,
  ),
  ford(
    id: 'ford',
    label: 'Ford or crossing',
    icon: Icons.water,
    garminSym: null,
    // Water's blue, lighter: a ford is water that is in the way rather than
    // water you came for.
    colour: Color(0xFF0288D1),
    group: WaypointIconGroup.travel,
  ),

  hazard(
    id: 'hazard',
    label: 'Hazard',
    icon: Icons.warning,
    garminSym: 'Skull and Crossbones',
    colour: Color(0xFFE65100),
    group: WaypointIconGroup.hazards,
  ),

  // GPX's trkType has no `sym` element at all, so these carry null rather than
  // a guess: nothing would be written for a track anyway, and a point given one
  // of these glyphs is a point, not a line.
  //
  // Their colours sit in hue regions the rest of the set leaves empty — pink,
  // indigo, dark brown, olive and near-black — because a track is a long thin
  // shape competing with roads and rivers on the basemap, and two tracks the
  // same colour are much harder to tell apart than two pins are.
  trail(
    id: 'trail',
    label: 'Trail',
    icon: Icons.route,
    garminSym: null,
    colour: Color(0xFFAD1457),
    group: WaypointIconGroup.lines,
  ),
  route(
    id: 'route',
    label: 'Planned route',
    icon: Icons.alt_route,
    garminSym: null,
    colour: Color(0xFF283593),
    group: WaypointIconGroup.lines,
  ),
  road(
    id: 'road',
    label: 'Access road',
    icon: Icons.directions_car,
    garminSym: null,
    colour: Color(0xFF3E2723),
    group: WaypointIconGroup.lines,
  ),
  portage(
    id: 'portage',
    label: 'Portage',
    icon: Icons.kayaking,
    garminSym: null,
    colour: Color(0xFF827717),
    group: WaypointIconGroup.lines,
  ),
  boundary(
    id: 'boundary',
    label: 'Boundary',
    icon: Icons.fence,
    garminSym: null,
    colour: Color(0xFF212121),
    group: WaypointIconGroup.lines,
  );

  const WaypointIcon({
    required this.id,
    required this.label,
    required this.icon,
    required this.garminSym,
    required this.colour,
    this.group = WaypointIconGroup.general,
  });

  /// Stable across releases: it is written into saved files and exports, and it
  /// is the filename of the generated SDF image, so renaming one silently
  /// changes the glyph on every waypoint already saved under it.
  final String id;

  final String label;

  /// Drawn in the app's own lists. The map draws the same glyph as an SDF image
  /// generated from this codepoint by `tools/icons/build_waypoint_icons.py`,
  /// and a test asserts the two have not drifted apart.
  final IconData icon;

  /// The exact Garmin symbol display name, or null where none fits.
  final String? garminSym;

  /// The tint this glyph draws in until the user picks a colour of their own.
  ///
  /// A property of the pictogram, not a classification: it is here so that a
  /// screen of thirty marks is a legible spread of colour instead of thirty
  /// identical pins, and so that a waypoint saved before the icon and the
  /// category were separated keeps the colour it already had.
  ///
  /// It is a default and a hint, never the meaning. Garmin has no waypoint
  /// colour field at all and onX discards colour on import, so colour must
  /// never be the only thing telling two glyphs apart — the pictogram always
  /// differs too, and that is deliberate.
  final Color colour;

  final WaypointIconGroup group;

  /// The MapLibre image name for this glyph's SDF asset.
  String get iconImage => 'owm-wp-$id';

  /// What a waypoint draws as until someone picks something else.
  static const fallback = WaypointIcon.pin;

  /// Every glyph, sectioned for a picker.
  ///
  /// Declaration order, so the picker reads in the order the enum does and a
  /// glyph added to a group lands beside the ones it belongs with.
  static Map<WaypointIconGroup, List<WaypointIcon>> get byGroup {
    final grouped = <WaypointIconGroup, List<WaypointIcon>>{};
    for (final icon in values) {
      (grouped[icon.group] ??= []).add(icon);
    }
    return grouped;
  }

  /// Resolves a stored or imported id, falling back to [fallback].
  ///
  /// Unknown ids are expected rather than exceptional: a file exported by a
  /// later build, or by another app that put something else in `<type>`. Losing
  /// the glyph is acceptable there. Losing the waypoint is not.
  static WaypointIcon fromId(String? id) {
    if (id == null) return fallback;
    final wanted = id.trim().toLowerCase();
    if (wanted.isEmpty) return fallback;
    for (final icon in values) {
      if (icon.id == wanted) return icon;
    }
    // Garmin round trips `<sym>` more reliably than `<type>` through some
    // tools, so a file that lost everything else can still be drawn from its
    // symbol.
    for (final icon in values) {
      if (icon.garminSym?.toLowerCase() == wanted) return icon;
    }
    // KML folder names are the human label, because that is what makes a folder
    // worth having in Google Earth. A file whose ExtendedData was stripped can
    // still be drawn from the folder it came out of.
    for (final icon in values) {
      if (icon.label.toLowerCase() == wanted) return icon;
    }
    return fallback;
  }
}
