import 'waypoint_icon.dart';

/// The fixed category list waypoints used to be filed under, kept only so that
/// files written before it was removed still read correctly.
///
/// A waypoint used to belong to exactly one of these twenty, and that decided
/// its glyph, its colour, its Garmin symbol and which section of the list it
/// appeared in. Classification is tags now. What survives here is the mapping a
/// stored `category` needs to become an icon and a tag.
///
/// The labels are duplicated from [WaypointIcon] on purpose rather than read
/// off it. They become tags on real devices the first time an old file is
/// loaded, so they are user data from that moment on: rewording an icon's label
/// later must not change the tag a migrated waypoint already carries, and must
/// not split one tag into two on a device that migrated at a different version.
const legacyCategoryLabels = <String, String>{
  'other': 'Other',
  'stand': 'Tree stand',
  'blind': 'Blind',
  'camera': 'Trail camera',
  'sign': 'Animal sign',
  'blood': 'Blood trail',
  'harvest': 'Harvest',
  'food': 'Food source',
  'water': 'Water source',
  'camp': 'Camp',
  'parking': 'Parking or access',
  'trailhead': 'Trailhead',
  'fishing': 'Fishing spot',
  'viewpoint': 'Viewpoint',
  'hazard': 'Hazard',
  'trail': 'Trail',
  'route': 'Planned route',
  'road': 'Access road',
  'portage': 'Portage',
  'boundary': 'Boundary walked',
};

/// The category id a stored or imported value names, or null if it names none.
///
/// Matches the label as well as the id, because a KML file that has been
/// through Google Earth may have lost its ExtendedData and arrive carrying only
/// a folder named "Boundary walked".
String? legacyCategoryId(String? value) {
  if (value == null) return null;
  final wanted = value.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  if (legacyCategoryLabels.containsKey(wanted)) return wanted;
  for (final entry in legacyCategoryLabels.entries) {
    if (entry.value.toLowerCase() == wanted) return entry.key;
  }
  return null;
}

/// The tags a category becomes, which is its label, or nothing.
///
/// Empty for `other` and for anything unrecognised. "Other" was the absence of
/// a choice rather than a choice, so carrying it forward would tag a large part
/// of an existing list with a word that classifies nothing — and a tag that
/// every waypoint has is a tag that cannot filter anything.
List<String> legacyCategoryTags(String? value) {
  final id = legacyCategoryId(value);
  if (id == null || id == 'other') return const [];
  return [legacyCategoryLabels[id]!.toLowerCase()];
}

/// The glyph a category used to draw as.
///
/// The ids are the same strings, so this is [WaypointIcon.fromId] — spelled out
/// here so that the migration reads as a migration and so an icon id changing
/// out from under it fails here rather than silently redrawing old waypoints.
WaypointIcon legacyCategoryIcon(String? value) {
  final id = legacyCategoryId(value);
  if (id == null) return WaypointIcon.fallback;
  return WaypointIcon.fromId(id);
}

/// The twenty old labels, offered in the editor as example tags.
///
/// They encode real knowledge about what people mark in the woods, and losing
/// them with the category list would have thrown that away. They are examples
/// and nothing more: nobody is expected to use them, and the editor has to show
/// them as clearly separate from the tags the user actually made.
///
/// "Other" is not in the list. It classified nothing when it was a category and
/// would classify nothing as a tag.
final suggestedTags = [
  for (final entry in legacyCategoryLabels.entries)
    if (entry.key != 'other') entry.value.toLowerCase(),
];
