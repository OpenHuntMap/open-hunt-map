import 'dart:convert';

import 'waypoint_colour.dart';
import 'waypoint_icon.dart';
import 'waypoint_storage_stub.dart'
    if (dart.library.io) 'waypoint_storage_io.dart'
    if (dart.library.html) 'waypoint_storage_web.dart' as storage;

/// How a tag itself is shown, where the tag is what is being shown.
///
/// The rule this type exists to keep: **a tag's icon and colour describe the
/// tag, not the waypoint.** They belong on the tag's filter chip and on its
/// section header, and nowhere else. A waypoint can carry several tags, so a
/// map symbol or a list row drawn from tag styling would have to pick one of
/// them, and there is no honest way to pick. The waypoint's own icon and colour
/// are what draw the waypoint.
///
/// Both fields are optional and a tag with neither is the normal case. Typing a
/// tag creates it immediately with no styling; styling it is a separate act
/// nobody has to perform.
class TagStyle {
  const TagStyle({this.icon, this.colour});

  final WaypointIcon? icon;
  final WaypointColour? colour;

  bool get isEmpty => icon == null && colour == null;

  /// Tolerant of absence and of values this build does not know, because this
  /// reads a file that a later build may have written.
  factory TagStyle.fromJson(Map<String, dynamic> json) => TagStyle(
        // Null rather than the fallback pin: a tag with no icon shows the
        // generic label glyph, and a chip that claimed a pin the user never
        // chose would read as styling that had been applied.
        icon: json['icon'] == null
            ? null
            : WaypointIcon.fromId(json['icon'] as String?),
        colour: WaypointColour.fromId(json['colour'] as String?),
      );

  Map<String, dynamic> toJson() => {
        if (icon != null) 'icon': icon!.id,
        if (colour != null) 'colour': colour!.id,
      };

  TagStyle copyWith({
    WaypointIcon? icon,
    bool clearIcon = false,
    WaypointColour? colour,
    bool clearColour = false,
  }) => TagStyle(
        icon: clearIcon ? null : (icon ?? this.icon),
        colour: clearColour ? null : (colour ?? this.colour),
      );
}

/// Tag styling, stored in its own file beside the waypoints.
///
/// Separate because the waypoints file's top-level JSON is a bare array, so
/// there is nowhere in it to put anything that is not a waypoint. Styling is
/// also per-tag rather than per-waypoint, and copying it onto every waypoint
/// that carries the tag would make the file the place two copies could disagree.
///
/// Nothing here is exported. GPX, KML and GeoJSON have no place for "what the
/// word 'ridge' looks like", and a private extension would be a format only
/// this app reads.
class TagStyleStore {
  Map<String, TagStyle> _styles = {};

  /// Every tag that has styling. Tags with none are absent rather than present
  /// and empty, so the file stays a record of choices that were made.
  Map<String, TagStyle> get styles => Map.unmodifiable(_styles);

  Future<void> load() async {
    final text = await storage.readTagStyleJson();
    if (text == null || text.trim().isEmpty) {
      _styles = {};
      return;
    }
    // Styling is decoration, so an unparseable file degrades to no styling
    // rather than being preserved the way an unreadable waypoint file is. The
    // waypoints are the irreplaceable thing; a colour on a chip can be chosen
    // again in two taps.
    try {
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final tags = decoded['tags'] as Map<String, dynamic>? ?? const {};
      _styles = {
        for (final entry in tags.entries)
          entry.key: TagStyle.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      };
    } catch (_) {
      _styles = {};
    }
  }

  /// Never null: a tag with no styling has an empty one, which every caller can
  /// draw without a null check.
  TagStyle styleFor(String tag) => _styles[tag] ?? const TagStyle();

  Future<void> setStyle(String tag, TagStyle style) async {
    if (style.isEmpty) {
      _styles.remove(tag);
    } else {
      _styles[tag] = style;
    }
    await _save();
  }

  /// A top-level object, not a bare array, precisely because the waypoints file
  /// is a bare array and has no room to grow. `version` is here so a later
  /// build can tell what it is reading.
  Future<void> _save() => storage.writeTagStyleJson(
        jsonEncode({
          'version': 1,
          'tags': {
            for (final entry in _styles.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      );
}
