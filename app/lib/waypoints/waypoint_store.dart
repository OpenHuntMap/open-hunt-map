import 'dart:convert';

import 'package:flutter/material.dart';

import '../tracks/track_style.dart';
import 'legacy_categories.dart';
import 'waypoint_colour.dart';
import 'waypoint_icon.dart';
import 'waypoint_storage_stub.dart'
    if (dart.library.io) 'waypoint_storage_io.dart'
    if (dart.library.html) 'waypoint_storage_web.dart' as storage;

class TrackPoint {
  const TrackPoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    this.time,
  });

  final double latitude;
  final double longitude;

  /// Metres above the ellipsoid, as the fix reported it, or null when it had
  /// none — which is every point of a track imported from a file that omitted
  /// `<ele>`.
  ///
  /// Carried so exports are complete and other tools can use it, but
  /// deliberately not summarised into a total ascent anywhere in the UI. A
  /// phone without a barometer reports elevation to a tolerance of tens of
  /// metres, and summing the noise over thousands of points produces a
  /// confident number that is wrong by a large factor. Storing the readings is
  /// honest; claiming a climb from them is not.
  final double? elevation;

  /// When the fix was taken. Null for imported points with no `<time>`, which
  /// is why [trackDuration] has to tolerate a track that has none.
  final DateTime? time;

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        elevation: (json['ele'] as num?)?.toDouble(),
        time: DateTime.tryParse(json['t'] as String? ?? ''),
      );

  /// Keys are abbreviated and nulls omitted because this is written once per
  /// fix: a few hours of walking is thousands of points, and spelling
  /// `elevation` in every one of them costs more than the values do.
  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
        if (elevation != null) 'ele': elevation,
        if (time != null) 't': time!.toIso8601String(),
      };
}

class Waypoint {
  const Waypoint({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.notes,
    required this.createdAt,
    this.icon = WaypointIcon.fallback,
    this.tags = const [],
    this.colour,
    this.track = const [],
    this.stroke = TrackStroke.solid,
    this.marker = TrackMarker.arrow,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String notes;
  final DateTime createdAt;

  /// The glyph this draws as, and nothing more.
  ///
  /// Single-valued because a symbol on a map has to be one picture, which is
  /// the one thing the old single-valued category was genuinely needed for.
  /// What the waypoint *is* lives in [tags].
  final WaypointIcon icon;

  /// The only classification a waypoint has. Lowercased and de-duplicated on
  /// the way in, so "Ridge" and "ridge" are one tag rather than two.
  final List<String> tags;

  /// Null means the glyph's own colour, which is different from having chosen
  /// that same colour: picking a different glyph repaints the first and leaves
  /// the second alone.
  final WaypointColour? colour;

  final List<TrackPoint> track;

  /// How the line is drawn. Set on every waypoint rather than only on tracks
  /// because a point simply never consults it, and a nullable field here would
  /// buy one saved byte in exchange for a null check at every use.
  final TrackStroke stroke;

  /// The direction marker repeated along the line.
  final TrackMarker marker;

  /// Whether this is a track, decided in one place.
  ///
  /// Two points are the least that makes a line, and the map has always drawn it
  /// that way. Four screens each had their own test — some `isNotEmpty`, some
  /// `length >= 2` — so a one-point track was listed as a track, described by its
  /// distance, offered a Follow menu, and drew nothing at all. Import now folds a
  /// lone point back into a point waypoint, which is what it is, and everything
  /// asks this.
  bool get isTrack => track.length >= 2;

  Color get displayColour => colour?.value ?? icon.colour;

  /// What MapLibre's `icon-color` gets.
  String get colourHex => hexColour(displayColour);

  /// Every field here is tolerant of absence, because this reads files written
  /// by builds that predate the field. A waypoint saved before icons existed is
  /// not corrupt, it just has a category instead.
  ///
  /// A stored `category` is migrated here rather than in the store, so that
  /// every path that reads a waypoint — the file, an old GeoJSON backup —
  /// migrates the same way. It becomes two things: the glyph that category drew
  /// as, and a tag carrying its label, because that label is the only record of
  /// how the user had classified the waypoint. The migrated form reaches disk on
  /// the next save; nothing is rewritten on load.
  factory Waypoint.fromJson(Map<String, dynamic> json) {
    final storedIcon = json['icon'] as String?;
    final legacy = storedIcon == null ? json['category'] as String? : null;
    return Waypoint(
      id: json['id'] as String,
      name: json['name'] as String,
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      notes: json['notes'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      icon: storedIcon == null
          ? legacyCategoryIcon(legacy)
          : WaypointIcon.fromId(storedIcon),
      // The category's label goes on the end rather than the front: a waypoint
      // the user had already tagged keeps reading in the order they typed.
      tags: normaliseTags([
        ...(json['tags'] as List<dynamic>? ?? const [])
            .map((tag) => tag.toString()),
        ...legacyCategoryTags(legacy),
      ]),
      colour: WaypointColour.fromId(json['colour'] as String?),
      track: (json['track'] as List<dynamic>? ?? const [])
          .map((item) => TrackPoint.fromJson(item as Map<String, dynamic>))
          .toList(),
      // Absent means a track saved before the look was choosable, which is a
      // solid line with arrows — what those tracks have always been drawn as.
      stroke: TrackStroke.fromId(json['stroke'] as String?),
      marker: TrackMarker.fromId(json['marker'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': latitude,
        'lng': longitude,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
        // No 'category'. Writing one would be writing a classification the app
        // no longer has, and an older build reading it back would trust it.
        'icon': icon.id,
        'tags': tags,
        // Omitted rather than written as the resolved colour, so "follows the
        // default" stays distinguishable from "happens to be that colour".
        if (colour != null) 'colour': colour!.id,
        'track': track.map((point) => point.toJson()).toList(),
        // Written only for lines, and only when not the default. A file of
        // several hundred points has no business carrying "solid" on every one
        // of them, and a point has no line to draw.
        if (isTrack && stroke != TrackStroke.solid) 'stroke': stroke.id,
        if (isTrack && marker != TrackMarker.arrow) 'marker': marker.id,
      };

  /// [clearColour] exists because passing `colour: null` cannot mean "unset" —
  /// that is indistinguishable from not passing it at all.
  Waypoint copyWith({
    String? name,
    String? notes,
    WaypointIcon? icon,
    List<String>? tags,
    WaypointColour? colour,
    bool clearColour = false,
    TrackStroke? stroke,
    TrackMarker? marker,
  }) => Waypoint(
        id: id,
        name: name ?? this.name,
        latitude: latitude,
        longitude: longitude,
        notes: notes ?? this.notes,
        createdAt: createdAt,
        icon: icon ?? this.icon,
        tags: tags == null ? this.tags : normaliseTags(tags),
        colour: clearColour ? null : (colour ?? this.colour),
        track: track,
        stroke: stroke ?? this.stroke,
        marker: marker ?? this.marker,
      );
}

/// Trims, lowercases, drops blanks and de-duplicates, preserving first-seen
/// order.
///
/// Tags are typed by hand and arrive from other people's files, so without this
/// a list picks up "Ridge", "ridge " and "ridge" as three separate things and
/// the filter chips multiply until they are useless.
List<String> normaliseTags(Iterable<String> tags) {
  final seen = <String>{};
  final result = <String>[];
  for (final tag in tags) {
    final clean = tag.trim().toLowerCase();
    if (clean.isEmpty || !seen.add(clean)) continue;
    result.add(clean);
  }
  return result;
}

/// Names a collection by what is actually in it: "3 waypoints and 1 track".
///
/// Tracks and waypoints share one store and one page, and that is right — they
/// are the same kind of belonging and people look for them in the same place.
/// But the copy was written when only points existed, so someone who had just
/// recorded a walk was told they had "1 waypoint", and a confirmation offered to
/// delete "2 waypoints" when one of them was an afternoon's walking. Whether that
/// matters is not ours to judge: the sentence should say what it will do.
String describeItems(Iterable<Waypoint> items) {
  var points = 0;
  var tracks = 0;
  for (final item in items) {
    if (item.isTrack) {
      tracks++;
    } else {
      points++;
    }
  }
  return describeItemCount(points: points, tracks: tracks);
}

String describeItemCount({required int points, required int tracks}) {
  String plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';
  return switch ((points, tracks)) {
    (0, 0) => 'nothing',
    (0, final t) => plural(t, 'track'),
    (final p, 0) => plural(p, 'waypoint'),
    (final p, final t) => '${plural(p, 'waypoint')} and ${plural(t, 'track')}',
  };
}

class WaypointStore {
  List<Waypoint> _items = [];
  List<Waypoint> get items => List.unmodifiable(_items);

  /// Where an unreadable waypoint file was moved to, if the last [load] hit one.
  ///
  /// Distinguishes "you have no waypoints" from "your waypoints are on disk and
  /// this build could not parse them". Both are an empty list and they deserve
  /// very different sentences, so the caller is expected to say the second one
  /// out loud and name this path.
  String? get unreadableFilePath => _unreadableFilePath;
  String? _unreadableFilePath;

  Future<List<Waypoint>> load() async {
    _unreadableFilePath = null;
    final text = await storage.readWaypointJson();
    if (text == null || text.trim().isEmpty) return _items = [];
    // A throw here used to escape into the map shell's bootstrap. This file is
    // the only copy of the user's waypoints, so one that is half-written or
    // written by a later build has to degrade into an empty list rather than
    // take the app down — and then it has to be moved out of the way, because
    // the next save would otherwise write two waypoints over all of them.
    try {
      final decoded = jsonDecode(text) as List<dynamic>;
      return _items = decoded
          .map((item) => Waypoint.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _unreadableFilePath = await storage.setAsideWaypointJson();
      return _items = [];
    }
  }

  Future<void> add(Waypoint waypoint) async {
    _items = [..._items, waypoint];
    await _save();
  }

  Future<void> update(Waypoint waypoint) async {
    _items = [
      for (final item in _items) if (item.id == waypoint.id) waypoint else item,
    ];
    await _save();
  }

  Future<void> delete(String id) async {
    _items = _items.where((item) => item.id != id).toList();
    await _save();
  }

  /// Every tag in use across the list, in first-seen order.
  List<String> get tagsInUse =>
      normaliseTags(_items.expand((item) => item.tags));

  /// How many waypoints carry each tag. Unused tags are absent rather than
  /// zero, so a filter row shows only what the user actually has.
  ///
  /// These do not sum to the number of waypoints, and cannot: a waypoint with
  /// three tags is counted three times, which is the point of tags. Anywhere
  /// these are shown has to say so, or the list appears to hold more than it
  /// does.
  Map<String, int> get tagCounts {
    final counts = <String, int>{};
    for (final item in _items) {
      for (final tag in item.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// How many waypoints carry no tags at all.
  ///
  /// Counted separately because they belong to no tag section, and a grouped
  /// view that only walks the tags loses every one of them.
  int get untaggedCount => _items.where((item) => item.tags.isEmpty).length;

  /// Deletes everything matching [test] and hands back what went.
  ///
  /// The return value is the whole point: clearing a tag removes many waypoints
  /// on one tap, with no per-row confirmation, so the caller has to be able to
  /// put them all back.
  Future<List<Waypoint>> deleteWhere(bool Function(Waypoint) test) async {
    final removed = _items.where(test).toList();
    if (removed.isEmpty) return removed;
    _items = _items.where((item) => !test(item)).toList();
    await _save();
    return removed;
  }

  /// Strips one tag from the waypoints named by [ids], keeping all of them.
  ///
  /// Exists as its own operation because with tags the two things a list
  /// section can be asked to do are genuinely different: unfiling a set of
  /// waypoints and destroying them. Returns how many were changed, so the
  /// caller can say what happened rather than "done".
  ///
  /// Scoped by id rather than sweeping every carrier of the tag, because the
  /// caller offers this from a section header that states a number, and a
  /// filtered list can be showing fewer than the tag has. Acting on more than
  /// the number in the menu is the kind of surprise that costs a season's work.
  Future<int> removeTagFrom(String tag, Set<String> ids) async {
    bool affected(Waypoint item) =>
        ids.contains(item.id) && item.tags.contains(tag);
    final changed = _items.where(affected).length;
    if (changed == 0) return 0;
    _items = [
      for (final item in _items)
        if (affected(item))
          item.copyWith(
            tags: item.tags.where((other) => other != tag).toList(),
          )
        else
          item,
    ];
    await _save();
    return changed;
  }

  Future<void> replaceAll(Iterable<Waypoint> waypoints) async {
    _items = waypoints.toList();
    await _save();
  }

  Future<void> _save() => storage.writeWaypointJson(
        jsonEncode(_items.map((item) => item.toJson()).toList()),
      );
}
