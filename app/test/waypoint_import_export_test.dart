import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/waypoints/import_export.dart';
import 'package:open_woods_map/waypoints/waypoint_store.dart';
import 'package:xml/xml.dart';

Waypoint point(String id, {String name = 'Stand', String notes = ''}) =>
    Waypoint(
      id: id,
      name: name,
      latitude: 45.26195,
      longitude: -77.62932,
      notes: notes,
      createdAt: DateTime.utc(2026, 9, 10, 16, 30),
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

      expect(children, ['time', 'name', 'desc', 'src']);
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
}
