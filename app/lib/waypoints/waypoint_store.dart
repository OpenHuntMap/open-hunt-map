import 'dart:convert';

import 'package:flutter/material.dart';

import '../tracks/track_style.dart';
import 'waypoint_category.dart';
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
    this.category = WaypointCategory.other,
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

  /// Single-valued and always set, because every app this exports to files
  /// waypoints under exactly one parent. [WaypointCategory.other] is the
  /// unclassified case rather than a null.
  final WaypointCategory category;

  /// The loose layer over [category]. Lowercased and de-duplicated on the way
  /// in, so "Ridge" and "ridge" are one tag rather than two.
  final List<String> tags;

  /// Null means "whatever the category's colour is", which is different from
  /// having chosen that same colour: a later change to the category's default
  /// follows the first and not the second.
  final WaypointColour? colour;

  final List<TrackPoint> track;

  /// How the line is drawn. Set on every waypoint rather than only on tracks
  /// because a point simply never consults it, and a nullable field here would
  /// buy one saved byte in exchange for a null check at every use.
  final TrackStroke stroke;

  /// The direction marker repeated along the line.
  final TrackMarker marker;

  Color get displayColour => colour?.value ?? category.colour;

  /// What MapLibre's `icon-color` gets.
  String get colourHex => hexColour(displayColour);

  /// Every field here is tolerant of absence, because this reads files written
  /// by builds that predate the field. A waypoint saved before categories
  /// existed is not corrupt, it is just uncategorised.
  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
        id: json['id'] as String,
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        category: WaypointCategory.fromId(json['category'] as String?),
        tags: normaliseTags(
          (json['tags'] as List<dynamic>? ?? const [])
              .map((tag) => tag.toString()),
        ),
        colour: WaypointColour.fromId(json['colour'] as String?),
        track: (json['track'] as List<dynamic>? ?? const [])
            .map((item) => TrackPoint.fromJson(item as Map<String, dynamic>))
            .toList(),
        // Absent means a track saved before the look was choosable, which is a
        // solid line with arrows — what those tracks have always been drawn as.
        stroke: TrackStroke.fromId(json['stroke'] as String?),
        marker: TrackMarker.fromId(json['marker'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': latitude,
        'lng': longitude,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
        'category': category.id,
        'tags': tags,
        // Omitted rather than written as the resolved colour, so "follows the
        // category" stays distinguishable from "happens to be that colour".
        if (colour != null) 'colour': colour!.id,
        'track': track.map((point) => point.toJson()).toList(),
        // Written only for lines, and only when not the default. A file of
        // several hundred points has no business carrying "solid" on every one
        // of them, and a point has no line to draw.
        if (track.isNotEmpty && stroke != TrackStroke.solid) 'stroke': stroke.id,
        if (track.isNotEmpty && marker != TrackMarker.arrow) 'marker': marker.id,
      };

  /// [clearColour] exists because passing `colour: null` cannot mean "unset" —
  /// that is indistinguishable from not passing it at all.
  Waypoint copyWith({
    String? name,
    String? notes,
    WaypointCategory? category,
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
        category: category ?? this.category,
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

  /// How many items sit in each category. Absent categories are absent rather
  /// than zero, so a filter row can show only what the user actually has.
  Map<WaypointCategory, int> get categoryCounts {
    final counts = <WaypointCategory, int>{};
    for (final item in _items) {
      counts[item.category] = (counts[item.category] ?? 0) + 1;
    }
    return counts;
  }

  /// Deletes everything matching [test] and hands back what went.
  ///
  /// The return value is the whole point: clearing a category removes many
  /// waypoints on one tap, with no per-row confirmation, so the caller has to be
  /// able to put them all back.
  Future<List<Waypoint>> deleteWhere(bool Function(Waypoint) test) async {
    final removed = _items.where(test).toList();
    if (removed.isEmpty) return removed;
    _items = _items.where((item) => !test(item)).toList();
    await _save();
    return removed;
  }

  Future<void> replaceAll(Iterable<Waypoint> waypoints) async {
    _items = waypoints.toList();
    await _save();
  }

  Future<void> _save() => storage.writeWaypointJson(
        jsonEncode(_items.map((item) => item.toJson()).toList()),
      );
}
