import 'dart:convert';

import 'waypoint_storage_stub.dart'
    if (dart.library.io) 'waypoint_storage_io.dart'
    if (dart.library.html) 'waypoint_storage_web.dart' as storage;

class TrackPoint {
  const TrackPoint({required this.latitude, required this.longitude});
  final double latitude;
  final double longitude;

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'lat': latitude, 'lng': longitude};
}

class Waypoint {
  const Waypoint({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.notes,
    required this.createdAt,
    this.track = const [],
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String notes;
  final DateTime createdAt;
  final List<TrackPoint> track;

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
        id: json['id'] as String,
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        track: (json['track'] as List<dynamic>? ?? const [])
            .map((item) => TrackPoint.fromJson(item as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': latitude,
        'lng': longitude,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
        'track': track.map((point) => point.toJson()).toList(),
      };

  Waypoint copyWith({String? name, String? notes}) => Waypoint(
        id: id,
        name: name ?? this.name,
        latitude: latitude,
        longitude: longitude,
        notes: notes ?? this.notes,
        createdAt: createdAt,
        track: track,
      );
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

  Future<void> replaceAll(Iterable<Waypoint> waypoints) async {
    _items = waypoints.toList();
    await _save();
  }

  Future<void> _save() => storage.writeWaypointJson(
        jsonEncode(_items.map((item) => item.toJson()).toList()),
      );
}
