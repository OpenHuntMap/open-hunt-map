import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' show Color;
import 'package:share_plus/share_plus.dart';
import 'package:xml/xml.dart';

import '../tracks/track_style.dart';
import 'legacy_categories.dart';
import 'waypoint_colour.dart';
import 'waypoint_icon.dart';
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
        // Says what is in the file. This is the line the recipient sees before
        // opening anything, and it was claiming waypoints when the file might be
        // nothing but tracks.
        subject: 'OpenWoodsMap — ${describeItems(waypoints)}',
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
        for (final waypoint in waypoints.where((item) => !item.isTrack)) {
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
              // field the tags survive a round trip back into this app in.
              if (waypoint.icon.garminSym case final sym?) {
                builder.element('sym', nest: sym);
              }
              if (_typeText(waypoint) case final type?) {
                builder.element('type', nest: type);
              }
            },
          );
        }
        for (final waypoint in waypoints.where(
          (item) => item.isTrack,
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
              if (_typeText(waypoint) case final type?) {
                builder.element('type', nest: type);
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

  /// KML, grouped into one folder per icon.
  ///
  /// Folders are the only grouping construct Google Earth, CalTopo and onX all
  /// understand, and a placemark can sit in exactly one of them. Tags cannot be
  /// folders for that reason: a waypoint carrying two tags would have to be
  /// written twice, and KML has no id, so anything re-importing the file — this
  /// app included — would have no way to tell the two copies apart from two
  /// waypoints. Duplicating a user's waypoints on a round trip is worse than a
  /// coarse folder.
  ///
  /// So the folder is the icon, which is the one thing a waypoint has exactly
  /// one of. Tags ride along in ExtendedData, where we can read them back but
  /// nothing else will.
  String toKml(List<Waypoint> waypoints) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    // Grouped up front so an unused icon produces no empty folder.
    final grouped = <WaypointIcon, List<Waypoint>>{};
    for (final waypoint in waypoints) {
      grouped.putIfAbsent(waypoint.icon, () => []).add(waypoint);
    }
    final styles = {for (final w in waypoints) w.colourHex};
    builder.element(
      'kml',
      attributes: {'xmlns': 'http://www.opengis.net/kml/2.2'},
      nest: () {
        builder.element(
          'Document',
          nest: () {
            builder.element(
              'name',
              nest: 'OpenWoodsMap — ${describeItems(waypoints)}',
            );
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
        // renamed by anything that touches the file; this is the machine copy,
        // and it is the only place the tags exist at all.
        builder.element(
          'ExtendedData',
          nest: () {
            _kmlData(builder, 'icon', waypoint.icon.id);
            if (waypoint.tags.isNotEmpty) {
              _kmlData(builder, 'tags', waypoint.tags.join(','));
            }
            if (waypoint.colour case final colour?) {
              _kmlData(builder, 'colour', colour.id);
            }
          },
        );
        if (!waypoint.isTrack) {
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
                      'icon': waypoint.icon.id,
                      'tags': waypoint.tags,
                      if (waypoint.colour case final colour?)
                        'colour': colour.id,
                      // How the line looks. Only GeoJSON carries this, and only
                      // because GeoJSON is this app's own backup format: GPX has
                      // no element for a stroke pattern and KML's LineStyle has
                      // colour and width but no dashes, so writing it into either
                      // would mean inventing an extension no other tool reads.
                      if (waypoint.isTrack) ...{
                        'stroke-style': waypoint.stroke.id,
                        'direction-marker': waypoint.marker.id,
                      },
                      // Not read back on import: it is derived from the two
                      // fields above. It is here so a GeoJSON viewer can draw
                      // the waypoint in the colour the user chose.
                      'marker-color': waypoint.colourHex,
                    },
                    'geometry': {
                      'type': waypoint.isTrack ? 'LineString' : 'Point',
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
              final type = _childText(element, 'type');
              return _waypoint(
                name,
                lat,
                lng,
                notes,
                time,
                icon: _iconFromGpx(_childText(element, 'sym'), type),
                tags: _tagsFromGpx(type, _childText(element, 'cmt')),
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
              final type = _childText(element, 'type');
              return _trackWaypoint(
                _childText(element, 'name') ?? 'Imported track',
                points,
                _childText(element, 'desc') ?? '',
                null,
                // trkType has no `sym`, so a track's glyph can only ever come
                // from what an older build left in `<type>`.
                icon: WaypointIcon.fromId(type),
                tags: _tagsFromGpx(type, _childText(element, 'cmt')),
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
          final icon = _iconFromKml(
            data['icon'],
            data['category'],
            _enclosingFolderName(element),
          );
          final tags = normaliseTags([
            ...(data['tags'] ?? '').split(',').map((tag) => tag.trim()),
            // Only from an explicit `category`, which nothing but an older
            // build of this app ever wrote, so it can only mean a classification
            // the user chose. Deliberately not taken from the folder name: a
            // folder is the icon's label now, and the twenty old category
            // labels are the same twenty strings, so a current file stripped of
            // its ExtendedData would otherwise arrive carrying a tag nobody
            // ever typed.
            ...legacyCategoryTags(data['category']),
          ]);
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
              icon: icon,
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
            icon: icon,
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
          // `category` is what an older backup carries. It migrates exactly as
          // a stored waypoint does — the glyph it drew as, plus its label as a
          // tag — because this is our own format and the value can have come
          // from nowhere else.
          final legacy = properties['icon'] == null
              ? properties['category']?.toString()
              : null;
          final icon = legacy == null
              ? WaypointIcon.fromId(properties['icon']?.toString())
              : legacyCategoryIcon(legacy);
          final tags = normaliseTags([
            ...(properties['tags'] as List<dynamic>? ?? const [])
                .map((tag) => tag.toString()),
            ...legacyCategoryTags(legacy),
          ]);
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
              icon: icon,
              tags: tags,
              colour: colour,
              // Absent in anyone else's GeoJSON, which is why both fall back to
              // the default rather than to nothing.
              stroke: TrackStroke.fromId(
                properties['stroke-style']?.toString(),
              ),
              marker: TrackMarker.fromId(
                properties['direction-marker']?.toString(),
              ),
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
            icon: icon,
            tags: tags,
            colour: colour,
          );
        })
        .whereType<Waypoint>()
        .toList();
  }

  /// The tags as readable text, for the one field every tool shows.
  ///
  /// Nothing in GPX or KML has a field for a many-valued grouping. Garmin's
  /// `gpxx:Categories` is the closest thing and its import side is undocumented
  /// and reported broken in BaseCamp, while onX and CalTopo have nothing at all.
  /// `<cmt>` at least shows up beside the waypoint in every one of them, so the
  /// tags stay legible to a person even though only this app parses them back.
  ///
  /// Null when there are no tags, because an empty comment is noise on the unit
  /// and the icon's own label is not a classification to put here in its place.
  String? _comment(Waypoint waypoint) {
    if (waypoint.tags.isEmpty) return null;
    return waypoint.tags.map((tag) => '#$tag').join(' ');
  }

  /// GPX `<type>`: the tags, comma separated, or nothing.
  ///
  /// `<type>` is free text with no agreed meaning, which is why it can carry
  /// something the format has no field for. Commas because that is the
  /// separator the tag editor already uses, and because the normalised form of
  /// a tag cannot contain one. Read back by splitting on commas, so this is the
  /// path that round trips tags through GPX exactly.
  ///
  /// Omitted rather than emitted empty: a `<type>` this app wrote means "these
  /// are the tags", and an empty one would mean "no tags" where the truth is
  /// often "this file never had any".
  String? _typeText(Waypoint waypoint) =>
      waypoint.tags.isEmpty ? null : waypoint.tags.join(',');

  /// Tags out of a GPX `<type>` and `<cmt>`, taking whatever each can give.
  ///
  /// The union of both, because they are written together but do not always
  /// arrive together: some tools drop `<type>`, others rewrite `<cmt>`. In a
  /// file this app wrote the two agree, so the union is the same list.
  ///
  /// `<type>` is read verbatim, which means a foreign file's type — "Geocache",
  /// or the category id an older build of this app wrote — becomes a tag as it
  /// is spelled. It is deliberately *not* translated back through the old
  /// category labels, even though the same string in a stored file is: half of
  /// those ids are words like "water", "camp" and "trail" that someone is very
  /// likely to have as a real tag, and rewriting a user's own tag into
  /// something else on a round trip is a worse failure than importing an old
  /// export's tag as "stand" rather than "tree stand".
  ///
  /// From `<cmt>`, only `#token` counts, so a sentence someone else wrote does
  /// not turn into tags.
  static List<String> _tagsFromGpx(String? type, String? comment) =>
      normaliseTags([
        ...(type ?? '').split(','),
        ...RegExp(r'#([\w-]+)')
            .allMatches(comment ?? '')
            .map((match) => match.group(1)!),
      ]);

  /// The glyph for an imported GPX feature.
  ///
  /// `<sym>` first: it is the only field in GPX that has ever meant an icon,
  /// and [WaypointIcon.fromId] matches Garmin's own names. `<type>` is the
  /// fallback only because an older build of this app wrote the category id
  /// there, which recovers the glyph for the handful of icons that have no
  /// Garmin symbol to be written as. Anything unrecognised falls back to the
  /// default pin rather than failing the import.
  static WaypointIcon _iconFromGpx(String? sym, String? type) {
    if (sym != null && sym.trim().isNotEmpty) return WaypointIcon.fromId(sym);
    return WaypointIcon.fromId(type);
  }

  /// The glyph for an imported KML placemark, in descending order of trust.
  ///
  /// The `icon` in ExtendedData is ours and exact. A `category` there is an
  /// older build's, and names a glyph that still exists. The folder name is
  /// whatever survived a tool rewriting the file, and is matched against both
  /// the current labels and the old ones, so "Tent" and "Boundary walked" both
  /// land somewhere sensible.
  static WaypointIcon _iconFromKml(
    String? stored,
    String? legacy,
    String? folder,
  ) {
    if (stored != null) return WaypointIcon.fromId(stored);
    if (legacyCategoryId(legacy) case final id?) return WaypointIcon.fromId(id);
    if (legacyCategoryId(folder) case final id?) return WaypointIcon.fromId(id);
    return WaypointIcon.fromId(folder);
  }

  Waypoint _waypoint(
    String name,
    double lat,
    double lng,
    String notes,
    DateTime? createdAt, {
    WaypointIcon icon = WaypointIcon.fallback,
    List<String> tags = const [],
    WaypointColour? colour,
  }) => Waypoint(
    id: _id(),
    name: name,
    latitude: lat,
    longitude: lng,
    notes: notes,
    createdAt: createdAt ?? DateTime.now(),
    icon: icon,
    tags: tags,
    colour: colour,
  );

  Waypoint? _trackWaypoint(
    String name,
    List<TrackPoint> points,
    String notes,
    DateTime? createdAt, {
    String? id,
    WaypointIcon icon = WaypointIcon.fallback,
    List<String> tags = const [],
    WaypointColour? colour,
    TrackStroke stroke = TrackStroke.solid,
    TrackMarker marker = TrackMarker.arrow,
  }) {
    if (points.isEmpty) return null;
    return Waypoint(
      id: id ?? _id(),
      name: name,
      latitude: points.first.latitude,
      longitude: points.first.longitude,
      notes: notes,
      createdAt: createdAt ?? DateTime.now(),
      icon: icon,
      tags: tags,
      colour: colour,
      // A single-point track is kept as the point it is. Other people's files do
      // contain one — a `trk` with one `trkpt` is what a recording that never got
      // a second fix looks like — and keeping the track list would have produced
      // an item listed as a track, described by its length, offered a Follow
      // menu, and drawing nothing whatsoever on the map. The coordinate is real
      // and worth keeping; the line is not there.
      track: points.length >= 2 ? points : const [],
      stroke: stroke,
      marker: marker,
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
