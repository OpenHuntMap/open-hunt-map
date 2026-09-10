import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/map/basemap.dart';
import 'package:open_woods_map/offline/basemap_sources.dart';

String readStyle(String name) =>
    File('assets/styles/$name.json').readAsStringSync();

LatLngBounds box(double west, double south, double east, double north) =>
    LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );

void main() {
  group('sourceSpecsFromStyle', () {
    test('reads the bundled satellite style', () {
      final specs = sourceSpecsFromStyle(readStyle('satellite'));
      expect(
        specs.map((s) => s.id).toSet(),
        {'sentinel2', 'on-ortho', 'qc-ortho'},
      );
      final sentinel = specs.firstWhere((s) => s.id == 'sentinel2');
      expect(sentinel.maxZoom, 14);
      expect(sentinel.bounds, isNull, reason: 'Sentinel-2 is worldwide');
      final ontario = specs.firstWhere((s) => s.id == 'on-ortho');
      expect(ontario.bounds, isNotNull);
      expect(ontario.minZoom, 8);
    });

    test('bounds are read longitude-first, as the style spec writes them', () {
      final ontario = sourceSpecsFromStyle(
        readStyle('satellite'),
      ).firstWhere((s) => s.id == 'on-ortho');
      // "bounds": [-95.3, 41.6, -74.2, 57.0]
      expect(ontario.bounds!.southwest.longitude, closeTo(-95.3, 0.001));
      expect(ontario.bounds!.southwest.latitude, closeTo(41.6, 0.001));
      expect(ontario.bounds!.northeast.longitude, closeTo(-74.2, 0.001));
      expect(ontario.bounds!.northeast.latitude, closeTo(57.0, 0.001));
    });

    test('the hybrid style adds vector tiles to the imagery', () {
      final specs = sourceSpecsFromStyle(readStyle('hybrid'));
      expect(specs.map((s) => s.id), contains('openmaptiles'));
      expect(specs.map((s) => s.id), contains('sentinel2'));
      final vector = specs.firstWhere((s) => s.id == 'openmaptiles');
      // Not in the style document, so it has to come from the fallback table.
      expect(vector.maxZoom, 14);
    });

    test('every source carries a measured tile weight', () {
      for (final name in ['satellite', 'hybrid']) {
        for (final spec in sourceSpecsFromStyle(readStyle(name))) {
          expect(
            spec.averageTileBytes,
            greaterThan(0),
            reason: '$name/${spec.id}',
          );
        }
      }
    });
  });

  group('the hybrid style', () {
    late Map<String, dynamic> style;

    setUpAll(() {
      style = json.decode(readStyle('hybrid')) as Map<String, dynamic>;
    });

    test('can render labels at all', () {
      expect(style['glyphs'], isNotNull);
      expect(style['sprite'], isNotNull);
    });

    test('draws imagery underneath the labels', () {
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      final lastRaster = layers.lastIndexWhere((l) => l['type'] == 'raster');
      final firstSymbol = layers.indexWhere((l) => l['type'] == 'symbol');
      expect(lastRaster, greaterThanOrEqualTo(0));
      expect(firstSymbol, greaterThan(lastRaster));
    });

    test('labels are light with a dark halo so imagery does not swallow them',
        () {
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      final symbols = layers.where(
        (l) => l['type'] == 'symbol' && l['id'] != 'highway-shield-non-us',
      );
      expect(symbols, isNotEmpty);
      for (final layer in symbols) {
        final paint = layer['paint'] as Map<String, dynamic>;
        expect(paint['text-color'], '#FFFFFF', reason: '${layer['id']}');
        expect(paint['text-halo-width'], greaterThan(1));
      }
    });

    test('carries road, water and place labels', () {
      final ids = (style['layers'] as List)
          .cast<Map<String, dynamic>>()
          .map((l) => l['id'])
          .toSet();
      expect(ids, containsAll(['label_town', 'water_name_point_label']));
      expect(ids, contains('highway-name-major'));
      expect(ids, contains('road_service_track'));
    });

    test('leaves out the clutter that imagery already shows', () {
      final ids = (style['layers'] as List)
          .cast<Map<String, dynamic>>()
          .map((l) => l['id'])
          .toSet();
      expect(ids, isNot(contains('building')));
      expect(ids, isNot(contains('landcover_wood')));
      expect(ids, isNot(contains('poi_r20')));
    });
  });

  group('pruneStyleToArea', () {
    test('drops a provincial source the area cannot reach', () {
      final northwestOntario = box(-94.0, 50.0, -93.0, 51.0);
      final pruned = json.decode(
        pruneStyleToArea(readStyle('satellite'), northwestOntario),
      ) as Map<String, dynamic>;
      final sources = (pruned['sources'] as Map).keys.toSet();
      expect(sources, contains('on-ortho'));
      expect(sources, contains('sentinel2'));
      expect(
        sources,
        isNot(contains('qc-ortho')),
        reason: 'Quebec imagery starts east of -79.9',
      );
    });

    test('drops the layers that used the pruned source', () {
      final northwestOntario = box(-94.0, 50.0, -93.0, 51.0);
      final pruned = json.decode(
        pruneStyleToArea(readStyle('satellite'), northwestOntario),
      ) as Map<String, dynamic>;
      final layerSources = (pruned['layers'] as List)
          .cast<Map<String, dynamic>>()
          .map((l) => l['source'])
          .whereType<String>()
          .toSet();
      expect(layerSources, isNot(contains('qc-ortho')));
      expect(layerSources, contains('on-ortho'));
    });

    test('keeps both provinces where they meet', () {
      final ottawaRiver = box(-76.0, 45.2, -75.4, 45.6);
      final pruned = json.decode(
        pruneStyleToArea(readStyle('satellite'), ottawaRiver),
      ) as Map<String, dynamic>;
      final sources = (pruned['sources'] as Map).keys.toSet();
      expect(sources, containsAll(['on-ortho', 'qc-ortho', 'sentinel2']));
    });

    test('the pruned style is still a valid style document', () {
      final area = box(-94.0, 50.0, -93.0, 51.0);
      final pruned = json.decode(pruneStyleToArea(readStyle('hybrid'), area))
          as Map<String, dynamic>;
      expect(pruned['version'], 8);
      expect(pruned['glyphs'], isNotNull);
      final sources = (pruned['sources'] as Map).keys.toSet();
      for (final layer in (pruned['layers'] as List)
          .cast<Map<String, dynamic>>()) {
        final source = layer['source'];
        if (source != null) expect(sources, contains(source));
      }
    });
  });

  group('detail ceiling', () {
    test('streets stops where OpenFreeMap stops', () {
      expect(detailCeilingFor(remoteSourceSpecs(BasemapKind.streets)), 14);
    });

    test('imagery goes deeper, but not past the cap we allow', () {
      final specs = sourceSpecsFromStyle(readStyle('satellite'));
      expect(detailCeilingFor(specs), maxOfflineZoom);
    });

    test('only labelled styles pay the glyph overhead', () {
      expect(
        overheadBytesFor(sourceSpecsFromStyle(readStyle('satellite'))),
        0,
      );
      expect(
        overheadBytesFor(sourceSpecsFromStyle(readStyle('hybrid'))),
        greaterThan(0),
      );
    });
  });

  group('basemaps', () {
    test('every basemap but the flat one can be saved offline', () {
      expect(BasemapKind.offline.supportsOfflineAreas, isFalse);
      for (final kind in BasemapKind.values) {
        if (kind == BasemapKind.offline) continue;
        expect(kind.supportsOfflineAreas, isTrue, reason: kind.name);
        expect(
          kind.assetStylePath ?? kind.remoteStyleUrl,
          isNotNull,
          reason: '${kind.name} needs a style to download',
        );
      }
    });
  });
}
