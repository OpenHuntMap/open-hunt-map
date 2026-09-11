import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' show Color;
import 'package:share_plus/share_plus.dart';
import 'package:xml/xml.dart';

import 'waypoint_category.dart';
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
              if (_comment(waypoint) case final comment?) {
                builder.element('cmt', nest: comment);
              }
              if (waypoint.notes.isNotEmpty) {
                builder.element('desc', nest: waypoint.notes);
              }
              builder.element('src', nest: 'OpenWoodsMap');
              // sym before type: still the wptType sequence. sym is what makes a
              // Garmin unit draw the right icon, and type is the free-text
              // category that survives a round trip back into this app.
              if (waypoint.category.garminSym case final sym?) {
                builder.element('sym', nest: sym);
              }
              builder.element('type', nest: waypoint.category.id);
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
              if (_comment(waypoint) case final comment?) {
                builder.element('cmt', nest: comment);
              }
              if (waypoint.notes.isNotEmpty) {
                builder.element('desc', nest: waypoint.notes);
              }
              builder.element('src', nest: 'OpenWoodsMap');
              builder.element('type', nest: waypoint.category.id);
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
                      // ele then time, and both before anything else: a trkpt
                      // is a wptType, so it is the same xsd:sequence the
                      // waypoints above follow. Omitted entirely when the fix
                      // had neither rather than written as zero, because a
                      // sea-level elevation is a claim and an absent one is not.
                      nest: () {
                        if (point.elevation case final elevation?) {
                          builder.element('ele', nest: elevation.toString());
                        }
                        if (point.time case final time?) {
                          builder.element(
                            'time',
                            nest: time.toUtc().toIso8601String(),
                          );
                        }
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

  /// KML, grouped into one folder per category.
  ///
  /// Folders are the only grouping construct Google Earth, CalTopo and onX all
  /// understand, and they are single-parent, which is why the category is
  /// single-valued in the first place. Tags ride along in ExtendedData, where we
  /// can read them back but nothing else will.
  String toKml(List<Waypoint> waypoints) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    // Grouped up front so an empty category produces no empty folder.
    final grouped = <WaypointCategory, List<Waypoint>>{};
    for (final waypoint in waypoints) {
      grouped.putIfAbsent(waypoint.category, () => []).add(waypoint);
    }
    final styles = {for (final w in waypoints) w.colourHex};
    builder.element(
      'kml',
      attributes: {'xmlns': 'http://www.opengis.net/kml/2.2'},
      nest: () {
        builder.element(
          'Document',
          nest: () {
            builder.element('name', nest: 'OpenWoodsMap waypoints');
            for (final hex in styles) {
              builder.element(
                'Style',
                attributes: {'id': _styleId(hex)},
                nest: () {
                  final kml = kmlColour(Color(0xFF000000 | _rgb(hex)));
                  // colorMode normal, so the icon takes our colour rather than
                  // Google Earth's default random tint.
                  builder.element(
                    'IconStyle',
                    nest: () {
                      builder.element('color', nest: kml);
                      builder.element('colorMode', nest: 'normal');
                    },
                  );
                  builder.element(
                    'LineStyle',
                    nest: () {
                      builder.element('color', nest: kml);
                      builder.element('width', nest: '3');
                    },
                  );
                },
              );
            }
            for (final entry in grouped.entries) {
              builder.element(
                'Folder',
                nest: () {
                  builder.element('name', nest: entry.key.label);
                  for (final waypoint in entry.value) {
                    _kmlPlacemark(builder, waypoint);
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

  void _kmlPlacemark(XmlBuilder builder, Waypoint waypoint) {
    builder.element(
      'Placemark',
      nest: () {
        builder.element('name', nest: waypoint.name);
        builder.element('description', nest: waypoint.notes);
        builder.element('styleUrl', nest: '#${_styleId(waypoint.colourHex)}');
        // The lossless path home. A folder name is the human label and can be
        // renamed by anything that touches the file; this is the machine copy.
        builder.element(
          'ExtendedData',
          nest: () {
            _kmlData(builder, 'category', waypoint.category.id);
            if (waypoint.tags.isNotEmpty) {
              _kmlData(builder, 'tags', waypoint.tags.join(','));
            }
            if (waypoint.colour case final colour?) {
              _kmlData(builder, 'colour', colour.id);
            }
          },
        );
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
              // Altitude stays 0 even for points that have one. KML only reads
              // the third coordinate when altitudeMode is `absolute`, and the
              // default here is clampToGround, which is what makes a walked
              // track lie on the terrain in Google Earth. Our elevations are
              // heights above the ellipsoid, so switching to absolute would
              // float or bury the line by tens of metres. GPX is the export
              // that carries elevation properly.
              builder.element(
                'coordinates',
                nest: waypoint.track
                    .map((point) => '${point.longitude},${point.latitude},0')
                    .join(' '),
              );
            },
          );
        }
      },
    );
  }

  void _kmlData(XmlBuilder builder, String name, String value) =>
      builder.element(
        'Data',
        attributes: {'name': name},
        nest: () => builder.element('value', nest: value),
      );

  /// A style id has to be an XML name, and `#B3261E` is not one.
  static String _styleId(String hex) => 'owm-${hex.replaceAll('#', '')}';

  static int _rgb(String hex) =>
      int.parse(hex.replaceAll('#', ''), radix: 16) & 0xFFFFFF;

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
                      'category': waypoint.category.id,
                      'tags': waypoint.tags,
                      if (waypoint.colour case final colour?)
                        'colour': colour.id,
                      // Not read back on import: it is derived from the two
                      // fields above. It is here so a GeoJSON viewer can draw
                      // the waypoint in the colour the user chose.
                      'marker-color': waypoint.colourHex,
                    },
                    'geometry': {
                      'type': waypoint.track.isEmpty ? 'Point' : 'LineString',
                      'coordinates':
                          waypoint.track.isEmpty
                              ? [waypoint.longitude, waypoint.latitude]
                              : _lineCoordinates(waypoint.track),
                    },
                  },
                )
                .toList(),
      });

  /// GeoJSON positions for a track, with altitude only when every point has it.
  ///
  /// RFC 7946 defines the optional third element as height in metres above the
  /// WGS84 ellipsoid, which is exactly what the platform reports, so unlike KML
  /// this is a place the elevation can go without reinterpretation. All or
  /// nothing: a mixed-length array is legal but trips strict readers, and
  /// filling the gaps with zero would be inventing sea-level readings.
  static List<List<double>> _lineCoordinates(List<TrackPoint> points) {
    final withElevation = points.every((point) => point.elevation != null);
    return [
      for (final point in points)
        if (withElevation)
          [point.longitude, point.latitude, point.elevation!]
        else
          [point.longitude, point.latitude],
    ];
  }

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
              // type first, then sym: type is what we wrote, sym is what a
              // Garmin unit is more likely to have preserved.
              return _waypoint(
                name,
                lat,
                lng,
                notes,
                time,
                category: WaypointCategory.fromId(
                  _childText(element, 'type') ?? _childText(element, 'sym'),
                ),
                tags: _tagsFromComment(_childText(element, 'cmt')),
              );
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
                          // Unparseable rather than absent is treated as absent.
                          // Other tools write `<ele></ele>` and non-UTC times,
                          // and one bad element should cost that point its
                          // elevation, not drop the whole track.
                          elevation: double.tryParse(
                            _childText(node, 'ele') ?? '',
                          ),
                          time: DateTime.tryParse(
                            _childText(node, 'time') ?? '',
                          ),
                        ),
                      )
                      .toList();
              return _trackWaypoint(
                _childText(element, 'name') ?? 'Imported track',
                points,
                _childText(element, 'desc') ?? '',
                null,
                category: WaypointCategory.fromId(
                  _childText(element, 'type'),
                ),
                tags: _tagsFromComment(_childText(element, 'cmt')),
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
          final data = _extendedData(element);
          // ExtendedData is ours and exact. The enclosing folder name is the
          // fallback, and it is why a file passed through Google Earth still
          // arrives sorted: fromId matches labels as well as ids.
          final category = WaypointCategory.fromId(
            data['category'] ?? _enclosingFolderName(element),
          );
          final tags = normaliseTags(
            (data['tags'] ?? '').split(',').map((tag) => tag.trim()),
          );
          final colour = WaypointColour.fromId(data['colour']);
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
            return _trackWaypoint(
              name,
              points,
              notes,
              null,
              category: category,
              tags: tags,
              colour: colour,
            );
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
            category: category,
            tags: tags,
            colour: colour,
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
          final category = WaypointCategory.fromId(
            properties['category']?.toString(),
          );
          final tags = normaliseTags(
            (properties['tags'] as List<dynamic>? ?? const [])
                .map((tag) => tag.toString()),
          );
          final colour = WaypointColour.fromId(properties['colour']?.toString());
          if (type == 'LineString') {
            final points =
                coordinates.map((item) {
                  final coordinate = item as List<dynamic>;
                  return TrackPoint(
                    latitude: (coordinate[1] as num).toDouble(),
                    longitude: (coordinate[0] as num).toDouble(),
                    // RFC 7946's optional third element. Read defensively
                    // because plenty of writers emit two.
                    elevation: coordinate.length > 2
                        ? (coordinate[2] as num?)?.toDouble()
                        : null,
                  );
                }).toList();
            return _trackWaypoint(
              properties['name']?.toString() ?? 'Imported track',
              points,
              properties['notes']?.toString() ?? '',
              DateTime.tryParse(properties['createdAt']?.toString() ?? ''),
              id: properties['id']?.toString(),
              category: category,
              tags: tags,
              colour: colour,
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
            category: category,
            tags: tags,
            colour: colour,
          );
        })
        .whereType<Waypoint>()
        .toList();
  }

  /// Carries the category label and the tags as readable text.
  ///
  /// Nothing in GPX or KML has a field for a many-valued grouping. Garmin's
  /// `gpxx:Categories` is the closest thing and its import side is undocumented
  /// and reported broken in BaseCamp, while onX and CalTopo have nothing at all.
  /// `<cmt>` at least shows up beside the waypoint in every one of them, so the
  /// tags stay legible to a person even though only this app parses them back.
  String? _comment(Waypoint waypoint) {
    final tags = waypoint.tags.map((tag) => '#$tag').join(' ');
    if (tags.isEmpty) return waypoint.category.label;
    return '${waypoint.category.label} · $tags';
  }

  /// The other half of [_comment]. Anything that is not a `#tag` token is left
  /// alone, so a comment a different app wrote does not become tags.
  static List<String> _tagsFromComment(String? comment) => normaliseTags(
    RegExp(r'#([\w-]+)')
        .allMatches(comment ?? '')
        .map((match) => match.group(1)!),
  );

  Waypoint _waypoint(
    String name,
    double lat,
    double lng,
    String notes,
    DateTime? createdAt, {
    WaypointCategory category = WaypointCategory.other,
    List<String> tags = const [],
    WaypointColour? colour,
  }) => Waypoint(
    id: _id(),
    name: name,
    latitude: lat,
    longitude: lng,
    notes: notes,
    createdAt: createdAt ?? DateTime.now(),
    category: category,
    tags: tags,
    colour: colour,
  );

  Waypoint? _trackWaypoint(
    String name,
    List<TrackPoint> points,
    String notes,
    DateTime? createdAt, {
    String? id,
    WaypointCategory category = WaypointCategory.other,
    List<String> tags = const [],
    WaypointColour? colour,
  }) {
    if (points.isEmpty) return null;
    return Waypoint(
      id: id ?? _id(),
      name: name,
      latitude: points.first.latitude,
      longitude: points.first.longitude,
      notes: notes,
      createdAt: createdAt ?? DateTime.now(),
      category: category,
      tags: tags,
      colour: colour,
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

  /// `<Data name="x"><value>y</value></Data>` pairs, flattened.
  Map<String, String> _extendedData(XmlElement element) {
    final extended = _firstDescendant(element, 'ExtendedData');
    if (extended == null) return const {};
    final data = <String, String>{};
    for (final node in extended.descendants.whereType<XmlElement>()) {
      if (node.name.local != 'Data') continue;
      final name = node.getAttribute('name');
      final value = _childText(node, 'value');
      if (name != null && value != null) data[name] = value;
    }
    return data;
  }

  /// The name of the Folder a Placemark sits in, if any.
  ///
  /// Walks up rather than down: a Folder can nest, and the nearest one is the
  /// one that describes this Placemark.
  String? _enclosingFolderName(XmlElement element) {
    for (var node = element.parentElement;
        node != null;
        node = node.parentElement) {
      if (node.name.local == 'Folder') return _childText(node, 'name');
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
