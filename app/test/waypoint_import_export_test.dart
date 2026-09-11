import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/import_export.dart';
import 'package:open_woods_map/waypoints/waypoint_category.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:xml/xml.dart';

Waypoint point(
  String id, {
  String name = 'Stand',
  String notes = '',
  WaypointCategory category = WaypointCategory.other,
  List<String> tags = const [],
  WaypointColour? colour,
}) => Waypoint(
  id: id,
  name: name,
  latitude: 45.26195,
  longitude: -77.62932,
  notes: notes,
  createdAt: DateTime.utc(2026, 9, 10, 16, 30),
  category: category,
  tags: tags,
  colour: colour,
);

Waypoint track(String id) => Waypoint(
  id: id,
  name: 'Morning walk',
  latitude: 45.1,
  longitude: -77.1,
  notes: '',
  createdAt: DateTime.utc(2026, 9, 10),
  track: const [
    TrackPoint(latitude: 45.1, longitude: -77.1),
    TrackPoint(latitude: 45.2, longitude: -77.2),
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
        transfer.toGpx([point('1', notes: 'Has a note, so desc is emitted')]),
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
  // leaving this app. Three separate carriers do that, and each is tested for
  // what it can and cannot promise.
  group('categories survive the trip out and back', () {
    group('GPX', () {
      test('sym is the exact Garmin name, so the unit draws the icon', () {
        final gpx = XmlDocument.parse(
          transfer.toGpx([point('1', category: WaypointCategory.stand)]),
        );
        expect(gpx.findAllElements('sym').single.innerText, 'Tree Stand');
      });

      test('sym is omitted where Garmin has no matching symbol', () {
        final gpx = XmlDocument.parse(
          transfer.toGpx([point('1', category: WaypointCategory.camera)]),
        );
        expect(gpx.findAllElements('sym'), isEmpty);
        // type still carries it, which is what brings it home.
        expect(gpx.findAllElements('type').single.innerText, 'camera');
      });

      test('type carries the category home again', () {
        final back = transfer.fromGpx(
          transfer.toGpx([point('1', category: WaypointCategory.blood)]),
        );
        expect(back.single.category, WaypointCategory.blood);
      });

      // A unit that dropped <type> but kept <sym> still sorts correctly,
      // because fromId matches Garmin's names too.
      test('a file with only sym still lands in the right category', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name><sym>Tree Stand</sym></wpt>
</gpx>''';
        expect(transfer.fromGpx(gpx).single.category, WaypointCategory.stand);
      });

      test('tags round trip through cmt', () {
        final back = transfer.fromGpx(
          transfer.toGpx([
            point('1', category: WaypointCategory.stand, tags: ['ridge', 'north']),
          ]),
        );
        expect(back.single.tags, ['ridge', 'north']);
      });

      // Someone else's comment must not become tags. Only #token counts.
      test('a comment written by another app does not become tags', () {
        const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.1" lon="-77.1"><name>A</name><cmt>Parked by the gate</cmt></wpt>
</gpx>''';
        expect(transfer.fromGpx(gpx).single.tags, isEmpty);
      });

      test('a track carries its category too', () {
        final back = transfer.fromGpx(
          transfer.toGpx([
            track('t1').copyWith(category: WaypointCategory.trailhead),
          ]),
        );
        expect(back.single.category, WaypointCategory.trailhead);
      });
    });

    group('KML', () {
      test('one folder per category, named for a human', () {
        final kml = XmlDocument.parse(
          transfer.toKml([
            point('1', category: WaypointCategory.stand),
            point('2', category: WaypointCategory.stand),
            point('3', category: WaypointCategory.water),
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

      test('an empty category produces no empty folder', () {
        final kml = XmlDocument.parse(
          transfer.toKml([point('1', category: WaypointCategory.stand)]),
        );
        expect(kml.findAllElements('Folder'), hasLength(1));
      });

      test('the category round trips exactly through ExtendedData', () {
        final back = transfer.fromKml(
          transfer.toKml([
            point('1', category: WaypointCategory.hazard, tags: ['creek']),
          ]),
        );
        expect(back.single.category, WaypointCategory.hazard);
        expect(back.single.tags, ['creek']);
      });

      // Google Earth and CalTopo both rewrite KML on save, and ExtendedData is
      // the first thing to go. The folder is the fallback.
      test('a file stripped of ExtendedData falls back to its folder', () {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Folder><name>Water source</name>
    <Placemark><name>Spring</name>
      <Point><coordinates>-77.1,45.1,0</coordinates></Point>
    </Placemark>
  </Folder>
</Document></kml>''';
        expect(transfer.fromKml(kml).single.category, WaypointCategory.water);
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
      test('keeps category, tags and the chosen colour', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([
            point(
              '1',
              category: WaypointCategory.camera,
              tags: ['ridge'],
              colour: WaypointColour.purple,
            ),
          ]),
        );
        expect(back.single.category, WaypointCategory.camera);
        expect(back.single.tags, ['ridge']);
        expect(back.single.colour, WaypointColour.purple);
      });

      // "Follows the category" has to stay distinguishable from "is that
      // colour", or a later change to a category default silently stops
      // applying to everything exported and re-imported since.
      test('a waypoint following its category comes back still following it', () {
        final back = transfer.fromGeoJson(
          transfer.toGeoJson([point('1', category: WaypointCategory.stand)]),
        );
        expect(back.single.colour, isNull);
        expect(back.single.displayColour, WaypointCategory.stand.colour);
      });
    });
  });
}
