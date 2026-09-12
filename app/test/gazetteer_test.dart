import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/gazetteer.dart';
import 'package:open_woods_map/data/province_loader.dart';
import 'package:open_woods_map/offline/offline_pack_store.dart';
import 'package:open_woods_map/search/coordinate_parser.dart';
import 'package:open_woods_map/search/coordinate_search_sheet.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Documents(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// Near Ottawa, and the same point the coordinate tests use, so "nearest" in
/// the expectations below means something a reader can picture.
const centreLatitude = 45.0;
const centreLongitude = -76.0;

/// A hand-built index in the shape `tools/gis/fetch_cgndb.py` writes.
///
/// The names are real CGNDB names and the duplicate Mud Lakes are the real
/// problem: Ontario has 75 of them, so a fixture with unique names would test
/// nothing that matters.
String indexJson({
  List<(String, String, String, double, double)> records = const [
    ('Mud Lake', 'Lake', 'Lanark', 45.0, -76.0),
    ('Muddy Creek', 'Watercourse', 'Renfrew', 45.1, -76.1),
    ('Big Mud Lake', 'Lake', 'Frontenac', 44.5, -76.5),
    ('Mud Lake', 'Lake', 'Algoma', 46.5, -82.0),
    ('Rivière Sainte-Anne', 'Watercourse', 'Portneuf', 46.9, -71.9),
    // Two "ss" in one name, which is what the scan's skip-ahead has to collapse
    // back into one result.
    ('Mississagi River', 'Watercourse', 'Algoma', 46.3, -83.0),
    ('Algonquin Provincial Park', 'Provincial Park', 'Nipissing', 45.8, -78.4),
    ('Shoal With No County', 'Shoal', '', 45.2, -76.2),
  ],
  String attribution =
      'Contains information licensed under the Open Government Licence – Canada.',
  int? recordCount,
  Map<String, Object?> overrides = const {},
}) {
  final types = <String>[];
  final contexts = <String>[];
  for (final (_, type, context, _, _) in records) {
    if (!types.contains(type)) types.add(type);
    if (!contexts.contains(context)) contexts.add(context);
  }
  return jsonEncode({
    'metadata': {
      'province': 'on',
      'province_name': 'Ontario',
      'record_count': recordCount ?? records.length,
      'coordinate_scale': 100000,
      'attribution': attribution,
      'coverage_note': 'Names approved by the Geographical Names Board.',
      'types': types,
      'contexts': contexts,
    },
    'names': [for (final record in records) record.$1],
    'type_ids': [for (final record in records) types.indexOf(record.$2)],
    'context_ids': [for (final record in records) contexts.indexOf(record.$3)],
    'lat_e5': [for (final record in records) (record.$4 * 100000).round()],
    'lon_e5': [for (final record in records) (record.$5 * 100000).round()],
    ...overrides,
  });
}

/// A pack that installs, optionally carrying a place-name index.
Uint8List packBytes({String? gazetteer, Map<String, Object?>? declaration}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'manifest.json',
        jsonEncode({
          'id': 'on',
          'name': 'Ontario',
          'version': '0.13.0',
          'layers': [
            {'id': 'crown_land', 'path': 'overlays/crown_land.geojson'},
          ],
          if (declaration != null) 'gazetteer': declaration,
        }),
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'overlays/crown_land.geojson',
        jsonEncode({
          'type': 'FeatureCollection',
          'metadata': <String, Object?>{},
          'features': <Object>[],
        }),
      ),
    );
  if (gazetteer != null) {
    archive.addFile(ArchiveFile.string('gazetteer/places.json', gazetteer));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const declaration = {
  'label': 'Place names',
  'path': 'gazetteer/places.json',
  'record_count': 8,
  'source': 'Canadian Geographical Names Database (Natural Resources Canada)',
  'license': 'Open Government Licence – Canada',
  'license_url': 'https://open.canada.ca/en/open-government-licence-canada',
  'attribution':
      'Contains information licensed under the Open Government Licence – Canada.',
};

List<String> namesOf(PlaceResults results) =>
    [for (final match in results.matches) '${match.name} (${match.context})'];

void main() {
  group('folding', () {
    // The case that decides whether Quebec search works at all: the source
    // spells it with accents and the keyboard makes them awkward to type.
    test('accents and case both come off', () {
      expect(foldForSearch('Rivière Sainte-Anne'), 'riviere sainte-anne');
      expect(foldForSearch('Île aux Cœurs'), 'ile aux coeurs');
      expect(foldForSearch('LAC À LA TRUITE'), 'lac a la truite');
    });

    test('a query folds the same way a record does', () {
      expect(foldForSearch('  Lac   Croché  '), foldForSearch('lac croche'));
    });

    test('the en dash the source uses reads as a hyphen', () {
      expect(foldForSearch('Saint\u2013Jean'), 'saint-jean');
    });
  });

  group('ranking', () {
    late GazetteerIndex index;

    setUp(() => index = GazetteerIndex.parse(indexJson()));

    // The whole point. "Big Mud Lake" contains the query but does not start
    // with it, so it loses to a Mud Lake 480 km away.
    test('a prefix match beats an interior one however far away it is', () {
      final matches = index.search(
        'mud',
        latitude: centreLatitude,
        longitude: centreLongitude,
      );
      expect(namesOf(matches), [
        'Mud Lake (Lanark)',
        'Muddy Creek (Renfrew)',
        'Mud Lake (Algoma)',
        'Big Mud Lake (Frontenac)',
      ]);
      expect(matches.matches.last.isPrefixMatch, isFalse);
      expect(matches.total, 4);
      expect(matches.isCapped, isFalse);
    });

    test('inside a class the nearest to the current view wins', () {
      final fromAlgoma = index.search(
        'mud lake',
        latitude: 46.5,
        longitude: -82.0,
      );
      expect(namesOf(fromAlgoma).first, 'Mud Lake (Algoma)');

      final fromOttawa = index.search(
        'mud lake',
        latitude: centreLatitude,
        longitude: centreLongitude,
      );
      expect(namesOf(fromOttawa).first, 'Mud Lake (Lanark)');
    });

    test('every match carries the type and county that tell them apart', () {
      final matches = index.search(
        'mud lake',
        latitude: centreLatitude,
        longitude: centreLongitude,
      ).matches;
      expect(matches.map((match) => match.featureType), everyElement('Lake'));
      expect(
        matches.map((match) => match.context).toList(),
        // Big Mud Lake is in there too: it contains "mud lake", it just does
        // not start with it, so it sorts last.
        ['Lanark', 'Algoma', 'Frontenac'],
      );
    });

    test('a blank county falls back to the province rather than an empty gap',
        () {
      final matches = index.search(
        'shoal with',
        latitude: centreLatitude,
        longitude: centreLongitude,
      ).matches;
      expect(matches.single.context, 'Ontario');
    });

    test('an unaccented query finds the accented name', () {
      final matches = index.search(
        'riviere sainte',
        latitude: centreLatitude,
        longitude: centreLongitude,
      ).matches;
      expect(matches.single.name, 'Rivière Sainte-Anne');
      expect(matches.single.isPrefixMatch, isTrue);
    });

    test('distance is measured from the view, not from the province', () {
      final matches = index.search(
        'algonquin',
        latitude: centreLatitude,
        longitude: centreLongitude,
      ).matches;
      // 45.0,-76.0 to 45.8,-78.4 is about 205 km.
      expect(matches.single.distanceMetres, closeTo(205000, 6000));
    });

    test('one letter is not searched', () {
      expect(
        index
            .search('m', latitude: centreLatitude, longitude: centreLongitude)
            .matches,
        isEmpty,
      );
    });

    // A name matched twice by the same query is still one place.
    test('a repeated substring inside one name yields one result', () {
      final matches = index.search(
        'ss',
        latitude: centreLatitude,
        longitude: centreLongitude,
      );
      expect(namesOf(matches), ['Mississagi River (Algoma)']);
      expect(matches.total, 1);
    });

    test('the limit caps the list but not the reported total', () {
      final capped = index.search(
        'la',
        latitude: centreLatitude,
        longitude: centreLongitude,
        limit: 1,
      );
      expect(capped.matches.length, 1);
      expect(capped.total, greaterThan(1));
      expect(capped.isCapped, isTrue);
      // The one kept is the best of them, not merely the first found.
      expect(capped.matches.single.name, 'Mud Lake');
    });

    test('asking for everything does not allocate more than the index', () {
      final all = index.search(
        'la',
        latitude: centreLatitude,
        longitude: centreLongitude,
        limit: 1 << 30,
      );
      expect(all.matches.length, all.total);
      expect(all.isCapped, isFalse);
    });
  });

  group('a damaged index refuses rather than searching part of a province', () {
    test('not JSON at all', () {
      expect(() => GazetteerIndex.parse('not json'), throwsA(isA<Exception>()));
    });

    test('columns of different lengths', () {
      expect(
        () => GazetteerIndex.parse(
          indexJson(overrides: {'lat_e5': [1, 2]}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a record count that disagrees with the records', () {
      expect(
        () => GazetteerIndex.parse(indexJson(recordCount: 99)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a type id with no type behind it', () {
      expect(
        () => GazetteerIndex.parse(
          indexJson(overrides: {'type_ids': [0, 0, 0, 0, 0, 0, 44]}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing column', () {
      expect(
        () => GazetteerIndex.parse(
          jsonEncode({'metadata': <String, Object?>{}}),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('loading it out of an installed pack', () {
    late Directory documents;
    late ProvinceLoader loader;

    setUp(() async {
      documents = await Directory.systemTemp.createTemp('owm-gazetteer-test');
      PathProviderPlatform.instance = _Documents(documents.path);
      SharedPreferences.setMockInitialValues({});
      loader = ProvinceLoader();
    });

    tearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });

    test('a pack carrying an index is searchable', () async {
      await installOfflinePack(
        'on',
        packBytes(gazetteer: indexJson(), declaration: declaration),
      );
      final result = await loader.loadGazetteer('on');
      expect(result.availability, GazetteerAvailability.ready);
      expect(result.index!.recordCount, 8);
      expect(result.index!.attribution, contains('Open Government Licence'));
    });

    // The first-run state, which is not an error.
    test('no pack installed says so', () async {
      expect(
        (await loader.loadGazetteer('on')).availability,
        GazetteerAvailability.noPack,
      );
    });

    // What a pack built before this feature looks like.
    test('a pack that declares no index says so', () async {
      await installOfflinePack('on', packBytes());
      expect(
        (await loader.loadGazetteer('on')).availability,
        GazetteerAvailability.notInPack,
      );
    });

    // A pack that promises an index and does not carry it is damaged, which is
    // a different thing to say than "built before this search existed".
    test('a declared index missing from the pack reads as damaged', () async {
      await installOfflinePack('on', packBytes(declaration: declaration));
      expect(
        (await loader.loadGazetteer('on')).availability,
        GazetteerAvailability.unreadable,
      );
    });

    test('a corrupt index says so rather than throwing', () async {
      await installOfflinePack(
        'on',
        packBytes(gazetteer: '{"metadata":', declaration: declaration),
      );
      expect(
        (await loader.loadGazetteer('on')).availability,
        GazetteerAvailability.unreadable,
      );
    });

    test('an index truncated to a valid-looking fragment is still refused',
        () async {
      await installOfflinePack(
        'on',
        packBytes(
          gazetteer: indexJson(overrides: {'names': ['Mud Lake']}),
          declaration: declaration,
        ),
      );
      expect(
        (await loader.loadGazetteer('on')).availability,
        GazetteerAvailability.unreadable,
      );
    });

    // Re-importing a pack mid-session used to be the bug that left stale data
    // presented as current, so the cache key has to move when the pack does.
    test('re-importing a pack is picked up rather than served from cache',
        () async {
      await installOfflinePack(
        'on',
        packBytes(gazetteer: indexJson(), declaration: declaration),
      );
      expect((await loader.loadGazetteer('on')).index!.recordCount, 8);

      await installOfflinePack(
        'on',
        packBytes(
          gazetteer: indexJson(
            records: const [('Otter Lake', 'Lake', 'Lanark', 45.0, -76.0)],
          ),
          declaration: {...declaration, 'record_count': 1},
        ),
      );
      expect((await loader.loadGazetteer('on')).index!.recordCount, 1);
    });
  });

  // The panel is given a loader that answers straight away. The real loader's
  // file reads and its worker isolate need the real event loop, which a widget
  // test's fake clock does not run, and the group above already drives that
  // path end to end through an installed pack.
  group('the search panel', () {
    Future<Coordinate?> Function() pump(
      WidgetTester tester,
      GazetteerResult gazetteer, {
      bool wired = true,
    }) {
      Coordinate? accepted;
      final pumped = tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoordinateSearchPanel(
              places: wired
                  ? PlaceSearchContext(
                      provinceId: 'on',
                      loader: _StubLoader(gazetteer),
                      centreLatitude: centreLatitude,
                      centreLongitude: centreLongitude,
                    )
                  : null,
              onAccept: (coordinate) => accepted = coordinate,
            ),
          ),
        ),
      );
      return () async {
        await pumped;
        await tester.pump();
        return accepted;
      };
    }

    GazetteerResult ready([String? json]) => GazetteerResult(
          GazetteerAvailability.ready,
          index: GazetteerIndex.parse(json ?? indexJson()),
        );

    testWidgets('a place name lists matches with type, county and distance',
        (tester) async {
      await pump(tester, ready())();

      await tester.enterText(find.byType(TextField), 'mud lake');
      await tester.pump();

      expect(find.text('Mud Lake'), findsNWidgets(2));
      expect(find.text('Lake · Lanark'), findsOneWidget);
      expect(find.text('Lake · Algoma'), findsOneWidget);
      expect(find.text('Lake · Frontenac'), findsOneWidget);
      expect(find.text('0 m'), findsOneWidget);
      expect(find.text('494 km'), findsOneWidget, reason: 'Algoma, far away');
      expect(find.textContaining('3 matches, nearest first'), findsOneWidget);
    });

    testWidgets('tapping a result hands back its coordinate and its name',
        (tester) async {
      final accepted = pump(tester, ready());
      await accepted();

      await tester.enterText(find.byType(TextField), 'algonquin');
      await tester.pump();
      await tester.tap(find.text('Algonquin Provincial Park'));

      final coordinate = await accepted();
      expect(coordinate, isNotNull);
      expect(coordinate!.latitude, closeTo(45.8, 1e-9));
      expect(coordinate.longitude, closeTo(-78.4, 1e-9));
      expect(coordinate.placeName, 'Algonquin Provincial Park');
    });

    // A licence condition, not a nicety.
    testWidgets('the licence credit is on screen once the index loads',
        (tester) async {
      await pump(tester, ready())();

      expect(
        find.textContaining('Open Government Licence – Canada'),
        findsOneWidget,
      );
    });

    // The easiest way to overclaim here, and the state somebody who typed a
    // road name lands in.
    testWidgets('no match says what this index is not', (tester) async {
      await pump(tester, ready())();

      await tester.enterText(find.byType(TextField), 'Highway 17');
      await tester.pump();

      expect(find.textContaining('not roads or trails'), findsOneWidget);
      expect(find.textContaining('known only locally'), findsOneWidget);
    });

    testWidgets('nothing on screen offers to search a road', (tester) async {
      await pump(tester, ready())();
      await tester.enterText(find.byType(TextField), 'mud');
      await tester.pump();

      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        final text = (widget.data ?? '').toLowerCase();
        expect(
          text.contains('road') || text.contains('trail'),
          isFalse,
          reason: 'unexpected mention of roads or trails in "$text"',
        );
      }
      // The label and the placeholder are where a promise would otherwise hide.
      expect(
        field(tester).decoration!.labelText,
        'Place name, coordinate or map link',
      );
      expect(field(tester).decoration!.hintText, '45.086428, -75.786970');
    });

    testWidgets('with no pack the panel says so and stays coordinate-capable',
        (tester) async {
      await pump(tester, const GazetteerResult(GazetteerAvailability.noPack))();

      expect(field(tester).decoration!.labelText, 'Coordinate or map link');
      await tester.enterText(find.byType(TextField), 'Mud Lake');
      await tester.pump();
      expect(find.textContaining('needs the ON map pack'), findsOneWidget);

      // The point of the degradation: coordinates keep working.
      await tester.enterText(find.byType(TextField), '45.086428, -75.786970');
      await tester.pump();
      expect(find.textContaining('Read as decimal degrees'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('with an older pack the panel explains the gap', (tester) async {
      await pump(
        tester,
        const GazetteerResult(GazetteerAvailability.notInPack),
      )();

      await tester.enterText(find.byType(TextField), 'Mud Lake');
      await tester.pump();
      expect(find.textContaining('carries no place names'), findsOneWidget);
      expect(field(tester).decoration!.labelText, 'Coordinate or map link');
    });

    testWidgets('with a corrupt index the panel explains that too',
        (tester) async {
      await pump(
        tester,
        const GazetteerResult(GazetteerAvailability.unreadable),
      )();

      await tester.enterText(find.byType(TextField), 'Mud Lake');
      await tester.pump();
      expect(find.textContaining('could not be read'), findsOneWidget);
    });

    testWidgets('unwired, the panel claims nothing about place names',
        (tester) async {
      await pump(tester, ready(), wired: false)();

      expect(field(tester).decoration!.labelText, 'Coordinate or map link');
      await tester.enterText(find.byType(TextField), 'Mud Lake');
      await tester.pump();
      expect(find.textContaining('no place-name index'), findsOneWidget);
    });

    testWidgets('a broken coordinate still gets its own reason, not a search',
        (tester) async {
      await pump(tester, ready())();

      await tester.enterText(find.byType(TextField), '45.0, 200.0');
      await tester.pump();
      expect(find.textContaining('between -180 and 180'), findsOneWidget);
      expect(find.text('Lake · Lanark'), findsNothing);
    });
  });

  // Measured against the real index rather than the fixture, because the
  // question is whether a scan over every approved name in Ontario is fast
  // enough to run on each keystroke. Skipped where the index has not been
  // built, since it is generated and gitignored.
  group('the real Ontario index', () {
    final file = File('../data/on/gazetteer/places.json');

    test('a full scan is fast enough to run while the user types', () {
      final json = file.readAsStringSync();
      final parseWatch = Stopwatch()..start();
      final index = GazetteerIndex.parse(json);
      parseWatch.stop();

      final timings = <String, String>{};
      // The limit the sheet actually uses, so the number means what a keystroke
      // costs rather than what an unbounded sort would.
      for (final query in ['mud', 'mud lake', 'algonq', 'riv', 'ottawa', 'la']) {
        var results = PlaceResults.empty;
        final watch = Stopwatch()..start();
        for (var repeat = 0; repeat < 20; repeat++) {
          results = index.search(
            query,
            latitude: centreLatitude,
            longitude: centreLongitude,
          );
        }
        watch.stop();
        timings[query] = '${(watch.elapsedMicroseconds / 20000)
            .toStringAsFixed(2)}ms/${results.total}';
        expect(results.total, greaterThan(0), reason: 'no match for "$query"');
      }

      // ignore: avoid_print
      print(
        'ON index: ${index.recordCount} records, '
        '${(file.lengthSync() / 1e6).toStringAsFixed(2)} MB, '
        'parse+fold ${parseWatch.elapsedMilliseconds} ms; '
        'search (time/matches) '
        '${timings.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
      );

      // The property that makes this fast is that a search costs about one pass
      // over the names and almost nothing per match. "la" matches 31,712 of the
      // 57,769 and "zq" matches none, so the two differ in what they match and
      // in nothing else — same query length, same bytes walked.
      // Ranking every match cost 69 ms against that baseline's 2 ms, a binary
      // search and a haversine per match cost 9 ms, and this ratio is what
      // catches either coming back.
      //
      // A wall-clock ceiling cannot: the whole suite runs in parallel, and the
      // printed figures above are four times slower under that contention than
      // the same code measured on an idle machine. Both halves of a ratio are
      // slowed equally, so it holds either way.
      double perSearch(String query) {
        final watch = Stopwatch()..start();
        for (var repeat = 0; repeat < 20; repeat++) {
          index.search(
            query,
            latitude: centreLatitude,
            longitude: centreLongitude,
          );
        }
        return watch.elapsedMicroseconds / 20;
      }

      final scanOnly = perSearch('zq');
      final everyMatch = perSearch('la');
      expect(
        everyMatch,
        lessThan(scanOnly * 5),
        reason: 'matching 31,712 names should cost little more than the scan; '
            'scan ${scanOnly.round()}us, worst case ${everyMatch.round()}us',
      );
    });

    test('a real duplicate name is ordered by distance from the view', () {
      final index = GazetteerIndex.parse(file.readAsStringSync());
      // Ontario has 75 Mud Lakes. From near Ottawa the first few must be the
      // eastern Ontario ones, not whichever the file happens to list first.
      final results = index.search(
        'mud lake',
        latitude: centreLatitude,
        longitude: centreLongitude,
      );
      final matches = results.matches;
      expect(results.total, greaterThan(40));
      expect(matches.first.isPrefixMatch, isTrue);
      for (var i = 1; i < matches.length; i++) {
        if (matches[i].isPrefixMatch != matches[i - 1].isPrefixMatch) continue;
        expect(
          matches[i].distanceMetres,
          greaterThanOrEqualTo(matches[i - 1].distanceMetres),
        );
      }
      expect(matches.first.distanceMetres, lessThan(200000));
    });

    // The search skips the distance calculation for any match too far north or
    // south to beat the fifty already kept. That is an optimisation on the real
    // record counts, not a nicety, but it would be a bad bug if the bound were
    // ever slightly too tight: the nearest lake would silently vanish from the
    // list. Asking for every match disables the bound, because the kept list
    // never fills, which gives an unpruned ranking to compare against.
    test('skipping distant matches does not change the answer', () {
      final index = GazetteerIndex.parse(file.readAsStringSync());
      for (final query in ['mud', 'riv', 'lake', 'mud lake']) {
        for (final centre in [
          (centreLatitude, centreLongitude),
          (48.4, -89.2), // Thunder Bay, the far side of the province
          (56.0, -88.0), // Hudson Bay coast, off the end of the data
        ]) {
          final pruned = index.search(
            query,
            latitude: centre.$1,
            longitude: centre.$2,
          );
          final reference = index.search(
            query,
            latitude: centre.$1,
            longitude: centre.$2,
            limit: index.recordCount,
          );
          expect(pruned.total, reference.total, reason: query);
          expect(
            pruned.matches.map((m) => m.name).toList(),
            reference.matches.take(pruned.matches.length).map((m) => m.name),
            reason: '"$query" from ${centre.$1}, ${centre.$2}',
          );
        }
      }
    });

    test('every Quebec accent in the source folds to something typeable', () {
      final quebec = File('../data/qc/gazetteer/places.json');
      if (!quebec.existsSync()) return;
      final index = GazetteerIndex.parse(quebec.readAsStringSync());
      // Lac Long is Quebec's Mud Lake, and the query carries no accents.
      final results = index.search(
        'riviere sainte-anne',
        latitude: 46.8,
        longitude: -71.2,
      );
      expect(results.total, greaterThan(0));
      expect(results.matches.first.name, contains('è'));
    });
  },
      skip: File('../data/on/gazetteer/places.json').existsSync()
          ? false
          : 'data/on/gazetteer/places.json is not built '
              '(python tools/gis/fetch_cgndb.py --province on)');
}

/// Answers from memory, so a widget test never waits on file I/O or an isolate.
class _StubLoader extends ProvinceLoader {
  _StubLoader(this.result);

  final GazetteerResult result;

  @override
  Future<GazetteerResult> loadGazetteer(String provinceId) async => result;
}

TextField field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));
