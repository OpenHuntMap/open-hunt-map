import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/tracks/track_style.dart';
import 'package:open_woods_map/waypoints/import_export.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:xml/xml.dart';

Waypoint point(
  String id, {
  String name = 'Stand',
  String notes = '',
  WaypointIcon icon = WaypointIcon.pin,
  List<String> tags = const [],
  WaypointColour? colour,
}) => Waypoint(
  id: id,
  name: name,
  latitude: 45.26195,
  longitude: -77.62932,
  notes: notes,
  createdAt: DateTime.utc(2026, 9, 10, 16, 30),
  icon: icon,
  tags: tags,
  colour: colour,
);

Waypoint track(
  String id, {
  List<TrackPoint>? points,
  TrackStroke stroke = TrackStroke.solid,
  TrackMarker marker = TrackMarker.arrow,
}) => Waypoint(
  id: id,
  name: 'Morning walk',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  stroke: stroke,
  marker: marker,
  track: points ??
      const [
        TrackPoint(latitude: 45.1, longitude: -77.1),
        TrackPoint(latitude: 45.2, longitude: -77.2),
      ],
);

/// A track whose points carry everything a recorded one would.
Waypoint timedTrack(String id) => track(
  id,
  points: [
    TrackPoint(
      latitude: 45.1,
      longitude: -77.1,
      elevation: 212.5,
      time: DateTime.utc(2026, 9, 10, 11, 0),
    ),
    TrackPoint(
      latitude: 45.2,
      longitude: -77.2,
      elevation: 248.25,
      time: DateTime.utc(2026, 9, 10, 11, 42, 30),
    ),
  ],
);

void main() {
  final transfer = WaypointImportExport();

  group('GPX', () {
    // GPX 1.1's wptType is an xsd:sequence, so a validating importer rejects a
    // file whose wpt children are in the wrong order. Garmin's are documented
    // to be strict, and this exporter had name before time.
    test('wpt children are in the order the schema requires', () {
      final gpx = XmlDocument.parse(
        // Tagged as well as noted, so that every element this exporter can
        // emit is present and the order of all of them is pinned down.
        transfer.toGpx([
          point(
            '1',
            notes: 'Has a note, so desc is emitted',
            tags: ['ridge'],
          ),
        ]),
      );
      final children = gpx
          .findAllElements('wpt')
          .single
          .childElements
          .map((element) => element.name.local)
          .toList();

      // GPX 1.1's wptType sequence runs ele, time, magvar, geoidheight, name,
      // cmt, desc, src, link, sym, type. Every element we emit has to appear in
      // that relative order or the file fails schema validation, which Garmin's
      // importers are documented to enforce.
      expect(children, [
        'time',
        'name',
        'cmt',
        'desc',
        'src',
        'sym',
        'type',
      ]);
    });

    test('a waypoint with no notes omits desc rather than emitting an empty '
        'one', () {
      final gpx = XmlDocument.parse(transfer.toGpx([point('1')]));
      expect(
        gpx.findAllElements('wpt').single.childElements
            .map((element) => element.name.local),
        isNot(contains('desc')),
      );
    });

    test('a track round-trips its points and their order', () {
      final gpx = transfer.toGpx([track('t1')]);
      final back = transfer.fromGpx(gpx);

      expect(back, hasLength(1));
      expect(back.single.track.map((p) => p.latitude), [45.1, 45.2]);
    });

    test('a point round-trips its name, notes and position', () {
      final back = transfer.fromGpx(
        transfer.toGpx([point('1', name: 'S5', notes: 'Game preserve')]),
      );

      expect(back.single.name, 'S5');
      expect(back.single.notes, 'Game preserve');
      expect(back.single.latitude, closeTo(45.26195, 1e-6));
      expect(back.single.longitude, closeTo(-77.62932, 1e-6));
    });
  });

  group('KML', () {
    test('a point round-trips', () {
      final back = transfer.fromKml(
        transfer.toKml([point('1', name: 'S5')]),
      );

      expect(back.single.name, 'S5');
      expect(back.single.latitude, closeTo(45.26195, 1e-6));
    });

    test('a track round-trips', () {
      final back = transfer.fromKml(transfer.toKml([track('t1')]));
      expect(back.single.track.map((p) => p.longitude), [-77.1, -77.2]);
    });

    test('altitude stays 0 even when the points have elevations', () {
      // Deliberate, not a gap. KML reads the third coordinate only under
      // altitudeMode `absolute`, and the default clampToGround is what puts a
      // walked track on the terrain in Google Earth. Our elevations are heights
      // above the ellipsoid, so absolute would float or bury the line.
      final kml = transfer.toKml([timedTrack('t1')]);
      expect(kml, contains('-77.1,45.1,0'));
      expect(kml, isNot(contains('212.5')));
    });

    // The reader used to take the first `coordinates` anywhere under the
    // Placemark, so anything nested alongside the geometry could win.
    test('a point inside a MultiGeometry still resolves', () {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark>
  <name>Wrapped</name>
  <MultiGeometry><Point><coordinates>-77.5,45.5,0</coordinates></Point></MultiGeometry>
</Placemark></Document></kml>''';

      final back = transfer.fromKml(kml);
      expect(back.single.latitude, closeTo(45.5, 1e-6));
      expect(back.single.longitude, closeTo(-77.5, 1e-6));
    });

    test('a Placemark with no geometry is dropped, not guessed at', () {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Placemark><name>Nothing here</name></Placemark>
</Document></kml>''';

      expect(transfer.fromKml(kml), isEmpty);
    });
  });

  group('GeoJSON', () {
    // The only one of the three formats that carries our id out and back, which
    // is what lets a re-imported backup be recognised instead of duplicated.
    test('an id survives the round trip', () {
      final back = transfer.fromGeoJson(
        transfer.toGeoJson([point('keep-me')]),
      );

      expect(back.single.id, 'keep-me');
    });

    test('a track keeps its id and its points', () {
      final back = transfer.fromGeoJson(
        transfer.toGeoJson([track('t1')]),
      );

      expect(back.single.id, 't1');
      expect(back.single.track, hasLength(2));
    });

    group('a track\'s look', () {
      test('round trips', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([
            track(
              't1',
              stroke: TrackStroke.dashed,
              marker: TrackMarker.doubleChevron,
            ),
          ]),
        );

        expect(back.single.stroke, TrackStroke.dashed);
        expect(back.single.marker, TrackMarker.doubleChevron);
      });

      test('is written under keys that say what they mean', () {
        final json =
            jsonDecode(
                  transfer.toGeoJson([
                    track('t1', stroke: TrackStroke.dotted),
                  ]),
                )
                as Map<String, dynamic>;
        final properties =
            (json['features'] as List).single['properties']
                as Map<String, dynamic>;

        expect(properties['stroke-style'], 'dotted');
        expect(properties['direction-marker'], 'arrow');
      });

      // A point has no line, so a stroke on one would be noise in the file and
      // a claim the app does not honour.
      test('is absent for a point', () {
        final json =
            jsonDecode(transfer.toGeoJson([point('1')])) as Map<String, dynamic>;
        final properties =
            (json['features'] as List).single['properties']
                as Map<String, dynamic>;

        expect(properties.containsKey('stroke-style'), isFalse);
        expect(properties.containsKey('direction-marker'), isFalse);
      });

      // Anyone else's GeoJSON has neither key, and a track from a file is a
      // solid line with arrows rather than nothing at all.
      test('defaults when the file is not ours', () {
        const foreign = '''
{"type":"FeatureCollection","features":[
  {"type":"Feature","properties":{"name":"Someone else's line"},
   "geometry":{"type":"LineString","coordinates":[[-77.1,45.1],[-77.2,45.2]]}}]}''';

        final back = transfer.fromGeoJson(foreign);
        expect(back.single.stroke, TrackStroke.solid);
        expect(back.single.marker, TrackMarker.arrow);
      });

      test('an unrecognised value falls back rather than throwing', () {
        const odd = '''
{"type":"FeatureCollection","features":[
  {"type":"Feature","properties":{"stroke-style":"zigzag","direction-marker":"barbs"},
   "geometry":{"type":"LineString","coordinates":[[-77.1,45.1],[-77.2,45.2]]}}]}''';

        final back = transfer.fromGeoJson(odd);
        expect(back.single.stroke, TrackStroke.solid);
        expect(back.single.marker, TrackMarker.arrow);
      });

      // Deliberate, and asserted so nobody "fixes" it later by inventing an
      // extension. GPX 1.1 has no element for a stroke pattern and KML's
      // LineStyle carries colour and width but no dashes, so anything written
      // there would be a private tag no other tool reads — and it would make the
      // file look richer than it is.
      test('is not smuggled into GPX or KML', () {
        final styled = track(
          't1',
          stroke: TrackStroke.dotted,
          marker: TrackMarker.chevron,
        );

        for (final text in [transfer.toGpx([styled]), transfer.toKml([styled])]) {
          expect(text, isNot(contains('dotted')));
          expect(text, isNot(contains('chevron')));
          expect(text, isNot(contains('stroke-style')));
          expect(text, isNot(contains('direction-marker')));
        }
      });
    });

    test('elevation rides in the third position element and comes back', () {
      // RFC 7946 defines it as metres above the WGS84 ellipsoid, which is what
      // the platform hands us, so no reinterpretation is needed here.
      final geoJson = transfer.toGeoJson([timedTrack('t1')]);
      final coordinates = (jsonDecode(geoJson)['features'] as List).single
          ['geometry']['coordinates'] as List;

      expect((coordinates.first as List), hasLength(3));
      expect((coordinates.first as List)[2], 212.5);
      expect(
        transfer.fromGeoJson(geoJson).single.track.map((p) => p.elevation),
        [212.5, 248.25],
      );
    });

    test('positions stay two long when any point lacks an elevation', () {
      // Zero-filling the gaps would invent sea-level readings, and a mixed-length
      // array trips strict readers, so the whole line drops to two.
      final mixed = track(
        't1',
        points: const [
          TrackPoint(latitude: 45.1, longitude: -77.1, elevation: 212.5),
          TrackPoint(latitude: 45.2, longitude: -77.2),
        ],
      );
      final coordinates = (jsonDecode(transfer.toGeoJson([mixed]))['features']
          as List).single['geometry']['coordinates'] as List;

      expect(coordinates.map((item) => (item as List).length), [2, 2]);
    });

    test('a two-element position from another writer still reads', () {
      const geoJson = '''
{"type":"FeatureCollection","features":[{"type":"Feature",
"properties":{"name":"Flat"},
"geometry":{"type":"LineString","coordinates":[[-77.1,45.1],[-77.2,45.2]]}}]}''';
      final points = transfer.fromGeoJson(geoJson).single.track;

      expect(points, hasLength(2));
      expect(points.first.elevation, isNull);
    });
  });

  group('ids', () {
    // Generated ids used to mix the clock with `DateTime.now().hashCode`, so a
    // loop importing several waypoints inside one microsecond could repeat one.
    // Harmless until import started skipping ids it already held; then two
    // imported waypoints would collapse into one.
    test('are unique across a single import of many waypoints', () {
      const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name></wpt>
  <wpt lat="45.2" lon="-77.2"><name>B</name></wpt>
  <wpt lat="45.3" lon="-77.3"><name>C</name></wpt>
  <wpt lat="45.4" lon="-77.4"><name>D</name></wpt>
</gpx>''';

      final imported = transfer.fromGpx(gpx);
      expect(imported, hasLength(4));
      expect(imported.map((item) => item.id).toSet(), hasLength(4));
    });
  });

  // What the user asked for is that the way they organise waypoints survives
  // leaving this app. The icon and the tags travel by different routes, and
  // each is tested for what it can and cannot promise.
  group('icons and tags survive the trip out and back', () {
    group('GPX', () {
      test('sym is the exact Garmin name, so the unit draws the icon', () {
        final gpx = XmlDocument.parse(
          transfer.toGpx([point('1', icon: WaypointIcon.stand)]),
        );
        expect(gpx.findAllElements('sym').single.innerText, 'Tree Stand');
      });

      test('sym is omitted where Garmin has no matching symbol', () {
        final gpx = XmlDocument.parse(
          transfer.toGpx([point('1', icon: WaypointIcon.camera)]),
        );
        expect(gpx.findAllElements('sym'), isEmpty);
      });

      // Nothing is invented for the glyphs added since the icon stopped being
      // a category. A plausible-looking name would put a wrong icon on the unit.
      test('sym is omitted for every glyph with no confirmed Garmin name', () {
        for (final icon in [WaypointIcon.tent, WaypointIcon.boatLaunch]) {
          final gpx = XmlDocument.parse(
            transfer.toGpx([point('1', icon: icon)]),
          );
          expect(gpx.findAllElements('sym'), isEmpty, reason: icon.id);
        }
      });

      test('sym brings the glyph home again', () {
        final back = transfer.fromGpx(
          transfer.toGpx([point('1', icon: WaypointIcon.blood)]),
        );
        expect(back.single.icon, WaypointIcon.blood);
      });

      // A glyph Garmin has no symbol for has nowhere to go in GPX at all, so it
      // comes back as the default pin. That is a real loss and it is the format
      // that cannot carry it; writing a near-miss symbol instead would be worse.
      test('a glyph with no sym is lost rather than approximated', () {
        final back = transfer.fromGpx(
          transfer.toGpx([point('1', icon: WaypointIcon.tent)]),
        );
        expect(back.single.icon, WaypointIcon.pin);
      });

      test('type carries the tags, comma separated', () {
        final gpx = XmlDocument.parse(
          transfer.toGpx([point('1', tags: ['ridge', 'north block'])]),
        );
        expect(
          gpx.findAllElements('type').single.innerText,
          'ridge,north block',
        );
      });

      // An empty <type> would say "no tags" where the truth is usually "this
      // file never had any".
      test('type is omitted when there are no tags', () {
        final gpx = XmlDocument.parse(transfer.toGpx([point('1')]));
        expect(gpx.findAllElements('type'), isEmpty);
        expect(gpx.findAllElements('cmt'), isEmpty);
      });

      test('tags round trip through type and cmt', () {
        final back = transfer.fromGpx(
          transfer.toGpx([
            point('1', icon: WaypointIcon.stand, tags: ['ridge', 'north']),
          ]),
        );
        expect(back.single.tags, ['ridge', 'north']);
      });

      test('a file with only cmt still recovers its tags', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name><cmt>#ridge #north</cmt></wpt>
</gpx>''';
        expect(transfer.fromGpx(gpx).single.tags, ['ridge', 'north']);
      });

      // An older build of this app wrote the category id here. It arrives as a
      // tag spelled the way the file spells it, and deliberately is not
      // translated back through the old labels: half those ids are words like
      // "water" and "camp" that someone is very likely to have as a real tag,
      // and rewriting a user's own tag on a round trip is the worse failure.
      test('an old export\'s type arrives as a tag, verbatim', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name>
    <sym>Tree Stand</sym><type>stand</type></wpt>
</gpx>''';
        final back = transfer.fromGpx(gpx).single;
        expect(back.icon, WaypointIcon.stand);
        expect(back.tags, ['stand']);
      });

      test('a tag that happens to be an old category id is not rewritten', () {
        final back = transfer.fromGpx(
          transfer.toGpx([point('1', tags: ['water', 'camp'])]),
        );
        expect(back.single.tags, ['water', 'camp']);
      });

      // Only for the glyphs Garmin cannot carry: sym wins whenever it is there,
      // so this cannot overrule a symbol the unit preserved.
      test('an old export\'s type recovers a glyph that has no sym', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name><type>camera</type></wpt>
</gpx>''';
        expect(transfer.fromGpx(gpx).single.icon, WaypointIcon.camera);
      });

      // Someone else's comment must not become tags. Only #token counts.
      test('a comment written by another app does not become tags', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name><cmt>Parked by the gate</cmt></wpt>
</gpx>''';
        expect(transfer.fromGpx(gpx).single.tags, isEmpty);
      });

      test('a track point keeps its elevation and time through GPX', () {
        final back = transfer.fromGpx(transfer.toGpx([timedTrack('t1')]));
        final points = back.single.track;

        expect(points.map((p) => p.elevation), [212.5, 248.25]);
        expect(points.first.time, DateTime.utc(2026, 9, 10, 11, 0));
        expect(points.last.time, DateTime.utc(2026, 9, 10, 11, 42, 30));
      });

      test('trkpt puts ele before time, and both before anything else', () {
        // trkpt is a wptType, so it is the same xsd:sequence the waypoints
        // follow: ele, time, then the rest. Garmin validates it.
        final gpx = XmlDocument.parse(transfer.toGpx([timedTrack('t1')]));
        final children = gpx
            .findAllElements('trkpt')
            .first
            .childElements
            .map((element) => element.name.local)
            .toList();

        expect(children, ['ele', 'time']);
      });

      test('times are written in UTC', () {
        final gpx = transfer.toGpx([timedTrack('t1')]);
        // A local-time stamp with no offset is the classic way a track lands an
        // hour out in another tool.
        expect(gpx, contains('2026-09-10T11:00:00.000Z'));
      });

      test('a point with no elevation or time writes neither element', () {
        final gpx = XmlDocument.parse(transfer.toGpx([track('t1')]));
        expect(gpx.findAllElements('trkpt').first.childElements, isEmpty);
        expect(gpx, isNot(contains('<ele/>')));
      });

      test('an empty or unparseable ele or time is treated as absent', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Odd</name><trkseg>
    <trkpt lat="45.1" lon="-77.1"><ele></ele><time>not a date</time></trkpt>
    <trkpt lat="45.2" lon="-77.2"><ele>210</ele></trkpt>
  </trkseg></trk>
</gpx>''';
        final points = transfer.fromGpx(gpx).single.track;

        expect(points, hasLength(2));
        expect(points.first.elevation, isNull);
        expect(points.first.time, isNull);
        expect(points.last.elevation, 210);
      });

      test('a track carries its tags too', () {
        final back = transfer.fromGpx(
          transfer.toGpx([track('t1').copyWith(tags: ['ridge'])]),
        );
        expect(back.single.tags, ['ridge']);
      });
    });

    group('KML', () {
      // Folders are the icon now, because a placemark sits in exactly one
      // folder and a waypoint has exactly one icon. Tags cannot be folders: a
      // waypoint with two tags would have to be written twice, KML has no id,
      // and re-importing would turn one waypoint into two.
      test('one folder per icon, named for a human', () {
        final kml = XmlDocument.parse(
          transfer.toKml([
            point('1', icon: WaypointIcon.stand),
            point('2', icon: WaypointIcon.stand),
            point('3', icon: WaypointIcon.water),
          ]),
        );
        final folders = kml.findAllElements('Folder').toList();
        expect(folders, hasLength(2));
        expect(
          folders.map((f) => f.findElements('name').single.innerText),
          containsAll(['Tree stand', 'Water source']),
        );
        // Two stands in one folder, not two folders of one.
        expect(folders.first.findAllElements('Placemark'), hasLength(2));
      });

      // The alternative — a folder per tag — would have written this one twice.
      test('a waypoint with two tags is written exactly once', () {
        final kml = XmlDocument.parse(
          transfer.toKml([point('1', tags: ['ridge', 'creek'])]),
        );
        expect(kml.findAllElements('Placemark'), hasLength(1));
        expect(transfer.fromKml(transfer.toKml([
          point('1', tags: ['ridge', 'creek']),
        ])), hasLength(1));
      });

      test('an unused icon produces no empty folder', () {
        final kml = XmlDocument.parse(
          transfer.toKml([point('1', icon: WaypointIcon.stand)]),
        );
        expect(kml.findAllElements('Folder'), hasLength(1));
      });

      test('the icon and the tags round trip through ExtendedData', () {
        final back = transfer.fromKml(
          transfer.toKml([
            point('1', icon: WaypointIcon.hazard, tags: ['creek', 'ridge']),
          ]),
        );
        expect(back.single.icon, WaypointIcon.hazard);
        expect(back.single.tags, ['creek', 'ridge']);
      });

      // Google Earth and CalTopo both rewrite KML on save, and ExtendedData is
      // the first thing to go. The folder is the fallback for the glyph.
      test('a file stripped of ExtendedData falls back to its folder', () {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Folder><name>Water source</name>
    <Placemark><name>Spring</name>
      <Point><coordinates>-77.1,45.1,0</coordinates></Point>
    </Placemark>
  </Folder>
</Document></kml>''';
        final back = transfer.fromKml(kml).single;
        expect(back.icon, WaypointIcon.water);
        // And no tag. The folder is the icon's label, and the twenty old
        // category labels are the same twenty strings, so taking a tag from a
        // folder name would invent one for every current file that lost its
        // ExtendedData.
        expect(back.tags, isEmpty);
      });

      test('a folder naming a glyph added since still resolves', () {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Folder><name>Tent</name>
    <Placemark><name>Flat spot</name>
      <Point><coordinates>-77.1,45.1,0</coordinates></Point>
    </Placemark>
  </Folder>
</Document></kml>''';
        expect(transfer.fromKml(kml).single.icon, WaypointIcon.tent);
      });

      // An older build of this app wrote `category` here. Unlike a folder name,
      // nothing else has ever written that element, so it can only mean a
      // classification the user chose — which is why this one does become a tag.
      test('an old export\'s category becomes a glyph and a tag', () {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Folder><name>Boundary walked</name>
    <Placemark><name>North line</name>
      <ExtendedData>
        <Data name="category"><value>boundary</value></Data>
        <Data name="tags"><value>creek</value></Data>
      </ExtendedData>
      <Point><coordinates>-77.1,45.1,0</coordinates></Point>
    </Placemark>
  </Folder>
</Document></kml>''';
        final back = transfer.fromKml(kml).single;
        expect(back.icon, WaypointIcon.boundary);
        expect(back.tags, ['creek', 'boundary walked']);
      });

      test('the colour is written in KML byte order, not RGB', () {
        final kml = XmlDocument.parse(
          transfer.toKml([point('1', colour: WaypointColour.red)]),
        );
        expect(
          kml.findAllElements('IconStyle').single
              .findElements('color')
              .single
              .innerText,
          kmlColour(WaypointColour.red.value),
        );
      });

      test('a style id is a legal XML name', () {
        final kml = XmlDocument.parse(
          transfer.toKml([point('1', colour: WaypointColour.red)]),
        );
        final id = kml.findAllElements('Style').single.getAttribute('id')!;
        expect(id, isNot(contains('#')));
        expect(
          kml.findAllElements('styleUrl').single.innerText,
          '#$id',
        );
      });
    });

    group('GeoJSON', () {
      // This is the app's own backup format and the only one that has to be
      // lossless. Anything it drops is gone from a restored backup.
      test('keeps the icon, the tags and the chosen colour', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([
            point(
              '1',
              icon: WaypointIcon.camera,
              tags: ['ridge', 'north block'],
              colour: WaypointColour.purple,
            ),
          ]),
        );
        expect(back.single.icon, WaypointIcon.camera);
        expect(back.single.tags, ['ridge', 'north block']);
        expect(back.single.colour, WaypointColour.purple);
      });

      test('every glyph round trips, including those GPX cannot carry', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([
            for (final icon in WaypointIcon.values)
              point(icon.id, icon: icon),
          ]),
        );
        expect(
          back.map((item) => item.icon),
          WaypointIcon.values,
        );
      });

      // "Follows the glyph" has to stay distinguishable from "is that colour",
      // or every waypoint exported and re-imported quietly stops following the
      // picture it is drawn with.
      test('a waypoint following its glyph comes back still following it', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([point('1', icon: WaypointIcon.stand)]),
        );
        expect(back.single.colour, isNull);
        expect(back.single.displayColour, WaypointIcon.stand.colour);
      });

      // An older backup carries `category`. This is our own format, so the
      // value can have come from nowhere else and migrates exactly as a stored
      // waypoint does.
      test('an old backup\'s category becomes a glyph and a tag', () {
        const geoJson = '''
{"type":"FeatureCollection","features":[{"type":"Feature",
"properties":{"id":"a","name":"North stand","category":"stand",
"tags":["ridge"]},
"geometry":{"type":"Point","coordinates":[-77.1,45.1]}}]}''';
        final back = transfer.fromGeoJson(geoJson).single;
        expect(back.icon, WaypointIcon.stand);
        expect(back.tags, ['ridge', 'tree stand']);
      });

      test('an icon id from a later build falls back rather than failing', () {
        const geoJson = '''
{"type":"FeatureCollection","features":[{"type":"Feature",
"properties":{"id":"a","name":"From the future","icon":"mineral-lick"},
"geometry":{"type":"Point","coordinates":[-77.1,45.1]}}]}''';
        final back = transfer.fromGeoJson(geoJson).single;
        expect(back.icon, WaypointIcon.pin);
        expect(back.name, 'From the future');
      });
    });
  });
}
