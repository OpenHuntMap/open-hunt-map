import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xml/xml.dart';

import 'waypoint_store.dart';

enum WaypointFormat { gpx, kml, geoJson }

class WaypointImportExport {
  Future<void> share(List<Waypoint> waypoints, WaypointFormat format) async {
    final (name, mime, content) = switch (format) {
      WaypointFormat.gpx => (
        'openwoodsmap.gpx',
        'application/gpx+xml',
        toGpx(waypoints),
      ),
      WaypointFormat.kml => (
        'openwoodsmap.kml',
        'application/vnd.google-earth.kml+xml',
        toKml(waypoints),
      ),
      WaypointFormat.geoJson => (
        'openwoodsmap.geojson',
        'application/geo+json',
        toGeoJson(waypoints),
      ),
    };
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(utf8.encode(content), mimeType: mime)],
        fileNameOverrides: [name],
        subject: 'OpenWoodsMap waypoints',
      ),
    );
  }

  Future<List<Waypoint>?> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gpx', 'kml', 'geojson', 'json'],
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const FormatException('The selected file could not be read.');
    }
    final text = utf8.decode(bytes);
    final extension = (file.extension ?? '').toLowerCase();
    return switch (extension) {
      'gpx' => fromGpx(text),
      'kml' => fromKml(text),
      'geojson' || 'json' => fromGeoJson(text),
      _ => throw const FormatException('Unsupported waypoint format.'),
    };
  }

  String toGpx(List<Waypoint> waypoints) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'gpx',
      attributes: {
        'version': '1.1',
        'creator': 'OpenWoodsMap',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
      },
      nest: () {
        for (final waypoint in waypoints.where((item) => item.track.isEmpty)) {
          builder.element(
            'wpt',
            attributes: {
              'lat': waypoint.latitude.toString(),
              'lon': waypoint.longitude.toString(),
            },
            nest: () {
              // GPX 1.1's wptType is an xsd:sequence, so the order here is not
              // cosmetic: ele, time, ..., name, cmt, desc, src, link, sym,
              // type. Emitting name before time makes the file fail schema
              // validation, and Garmin's importers are documented to be strict.
              builder.element(
                'time',
                nest: waypoint.createdAt.toUtc().toIso8601String(),
              );
              builder.element('name', nest: waypoint.name);
              if (waypoint.notes.isNotEmpty) {
                builder.element('desc', nest: waypoint.notes);
              }
              builder.element('src', nest: 'OpenWoodsMap');
            },
          );
        }
        for (final waypoint in waypoints.where(
          (item) => item.track.isNotEmpty,
        )) {
          builder.element(
            'trk',
            nest: () {
              builder.element('name', nest: waypoint.name);
              if (waypoint.notes.isNotEmpty) {
                builder.element('desc', nest: waypoint.notes);
              }
              builder.element(
                'trkseg',
                nest: () {
                  for (final point in waypoint.track) {
                    builder.element(
                      'trkpt',
                      attributes: {
                        'lat': point.latitude.toString(),
                        'lon': point.longitude.toString(),
                      },
                    );
                  }
                },
              );
            },
          );
        }
      },
    );
    return builder.buildDocument().toXmlString(pretty: true);
  }

  String toKml(List<Waypoint> waypoints) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'kml',
      attributes: {'xmlns': 'http://www.opengis.net/kml/2.2'},
      nest: () {
        builder.element(
          'Document',
          nest: () {
            for (final waypoint in waypoints) {
              builder.element(
                'Placemark',
                nest: () {
                  builder.element('name', nest: waypoint.name);
                  builder.element('description', nest: waypoint.notes);
                  if (waypoint.track.isEmpty) {
                    builder.element(
                      'Point',
                      nest: () {
                        builder.element(
                          'coordinates',
                          nest: '${waypoint.longitude},${waypoint.latitude},0',
                        );
                      },
                    );
                  } else {
                    builder.element(
                      'LineString',
                      nest: () {
                        builder.element('tessellate', nest: '1');
                        builder.element(
                          'coordinates',
                          nest: waypoint.track
                              .map(
                                (point) =>
                                    '${point.longitude},${point.latitude},0',
                              )
                              .join(' '),
                        );
                      },
                    );
                  }
                },
              );
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true);
  }

  String toGeoJson(List<Waypoint> waypoints) =>
      const JsonEncoder.withIndent('  ').convert({
        'type': 'FeatureCollection',
        'features':
            waypoints
                .map(
                  (waypoint) => {
                    'type': 'Feature',
                    'properties': {
                      'id': waypoint.id,
                      'name': waypoint.name,
                      'notes': waypoint.notes,
                      'createdAt': waypoint.createdAt.toIso8601String(),
                    },
                    'geometry': {
                      'type': waypoint.track.isEmpty ? 'Point' : 'LineString',
                      'coordinates':
                          waypoint.track.isEmpty
                              ? [waypoint.longitude, waypoint.latitude]
                              : [
                                for (final point in waypoint.track)
                                  [point.longitude, point.latitude],
                              ],
                    },
                  },
                )
                .toList(),
      });

  List<Waypoint> fromGpx(String text) {
    final document = XmlDocument.parse(text);
    final waypoints =
        document.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'wpt')
            .map((element) {
              final lat = double.parse(element.getAttribute('lat')!);
              final lng = double.parse(element.getAttribute('lon')!);
              final name = _childText(element, 'name') ?? 'Imported waypoint';
              final notes = _childText(element, 'desc') ?? '';
              final time = DateTime.tryParse(_childText(element, 'time') ?? '');
              return _waypoint(name, lat, lng, notes, time);
            })
            .toList();
    final tracks =
        document.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'trk')
            .map((element) {
              final points =
                  element.descendants
                      .whereType<XmlElement>()
                      .where((node) => node.name.local == 'trkpt')
                      .map(
                        (node) => TrackPoint(
                          latitude: double.parse(node.getAttribute('lat')!),
                          longitude: double.parse(node.getAttribute('lon')!),
                        ),
                      )
                      .toList();
              return _trackWaypoint(
                _childText(element, 'name') ?? 'Imported track',
                points,
                _childText(element, 'desc') ?? '',
                null,
              );
            })
            .whereType<Waypoint>();
    return [...waypoints, ...tracks];
  }

  List<Waypoint> fromKml(String text) {
    final document = XmlDocument.parse(text);
    return document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'Placemark')
        .map((element) {
          final name = _childText(element, 'name') ?? 'Imported waypoint';
          final notes = _childText(element, 'description') ?? '';
          final lineString = _firstDescendant(element, 'LineString');
          if (lineString != null) {
            final coordinateText = _childText(lineString, 'coordinates') ?? '';
            final points =
                coordinateText
                    .trim()
                    .split(RegExp(r'\s+'))
                    .where((value) => value.isNotEmpty)
                    .map((value) {
                      final coordinates = value.split(',');
                      return TrackPoint(
                        latitude: double.parse(coordinates[1]),
                        longitude: double.parse(coordinates[0]),
                      );
                    })
                    .toList();
            return _trackWaypoint(name, points, notes, null);
          }
          // Via the Point rather than straight to the coordinates, so a
          // Placemark wrapped in a MultiGeometry still resolves and a stray
          // coordinates element elsewhere in it cannot win.
          final point = _firstDescendant(element, 'Point');
          final coordinateText = point == null
              ? null
              : _childText(point, 'coordinates');
          if (coordinateText == null) return null;
          final coordinates = coordinateText.trim().split(',');
          return _waypoint(
            name,
            double.parse(coordinates[1]),
            double.parse(coordinates[0]),
            notes,
            null,
          );
        })
        .whereType<Waypoint>()
        .toList();
  }

  List<Waypoint> fromGeoJson(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return (json['features'] as List<dynamic>? ?? const [])
        .map((item) {
          final feature = item as Map<String, dynamic>;
          final properties = Map<String, dynamic>.from(
            feature['properties'] as Map? ?? const {},
          );
          final geometry = feature['geometry'] as Map<String, dynamic>;
          final coordinates = geometry['coordinates'] as List<dynamic>;
          final type = geometry['type']?.toString();
          if (type == 'LineString') {
            final points =
                coordinates.map((item) {
                  final coordinate = item as List<dynamic>;
                  return TrackPoint(
                    latitude: (coordinate[1] as num).toDouble(),
                    longitude: (coordinate[0] as num).toDouble(),
                  );
                }).toList();
            return _trackWaypoint(
              properties['name']?.toString() ?? 'Imported track',
              points,
              properties['notes']?.toString() ?? '',
              DateTime.tryParse(properties['createdAt']?.toString() ?? ''),
              id: properties['id']?.toString(),
            );
          }
          if (type != 'Point') return null;
          return Waypoint(
            id: properties['id']?.toString() ?? _id(),
            name: properties['name']?.toString() ?? 'Imported waypoint',
            latitude: (coordinates[1] as num).toDouble(),
            longitude: (coordinates[0] as num).toDouble(),
            notes: properties['notes']?.toString() ?? '',
            createdAt:
                DateTime.tryParse(properties['createdAt']?.toString() ?? '') ??
                DateTime.now(),
          );
        })
        .whereType<Waypoint>()
        .toList();
  }

  Waypoint _waypoint(
    String name,
    double lat,
    double lng,
    String notes,
    DateTime? createdAt,
  ) => Waypoint(
    id: _id(),
    name: name,
    latitude: lat,
    longitude: lng,
    notes: notes,
    createdAt: createdAt ?? DateTime.now(),
  );

  Waypoint? _trackWaypoint(
    String name,
    List<TrackPoint> points,
    String notes,
    DateTime? createdAt, {
    String? id,
  }) {
    if (points.isEmpty) return null;
    return Waypoint(
      id: id ?? _id(),
      name: name,
      latitude: points.first.latitude,
      longitude: points.first.longitude,
      notes: notes,
      createdAt: createdAt ?? DateTime.now(),
      track: points,
    );
  }

  /// Direct children only.
  ///
  /// This used to walk every descendant, which happens to work on the flat
  /// documents we write today and stops working the moment anything is nested:
  /// a `<name>` inside an extension or a style would win over the feature's own.
  String? _childText(XmlElement element, String localName) {
    for (final node in element.childElements) {
      if (node.name.local == localName) return node.innerText;
    }
    return null;
  }

  XmlElement? _firstDescendant(XmlElement element, String localName) => element
      .descendants
      .whereType<XmlElement>()
      .where((node) => node.name.local == localName)
      .firstOrNull;

  /// Unique within a run as well as between runs.
  ///
  /// An import loop can call this many times inside the same microsecond, and
  /// ids stopped being cosmetic once import began skipping the ones it already
  /// holds — two imported waypoints sharing an id would collapse into one.
  static var _sequence = 0;

  static String _id() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
}
