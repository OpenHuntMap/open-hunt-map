import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/offline/tile_math.dart';

LatLngBounds box(double west, double south, double east, double north) =>
    LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );

void main() {
  group('tileRectFor', () {
    test('the whole world is one tile at zoom 0', () {
      final rect = tileRectFor(box(-180, -85, 180, 85), 0);
      expect(rect.count, 1);
      expect(rect.minX, 0);
      expect(rect.minY, 0);
    });

    test('north-east of null island is the north-east quadrant at zoom 1', () {
      final rect = tileRectFor(box(0.1, 0.1, 0.2, 0.2), 1);
      expect(rect.minX, 1);
      expect(rect.minY, 0);
    });

    test('tile Y increases southwards', () {
      final north = tileRectFor(box(-76, 50, -75, 51), 8);
      final south = tileRectFor(box(-76, 44, -75, 45), 8);
      expect(north.minY, lessThan(south.minY));
    });

    test('latitudes past the Mercator limit are clamped, not wrapped', () {
      final rect = tileRectFor(box(-10, -89, 10, 89), 4);
      expect(rect.minY, greaterThanOrEqualTo(0));
      expect(rect.maxY, lessThan(1 << 4));
    });

    test('a wider area needs more tiles', () {
      final small = tileRectFor(box(-76, 45, -75.9, 45.1), 12);
      final large = tileRectFor(box(-76, 45, -75, 46), 12);
      expect(large.count, greaterThan(small.count));
    });
  });

  group('uncoveredTileCount', () {
    final target = TileRect(minX: 0, minY: 0, maxX: 9, maxY: 9);

    test('nothing saved means everything is new', () {
      expect(uncoveredTileCount(target, const []), 100);
    });

    test('a disjoint area discounts nothing', () {
      final elsewhere = TileRect(minX: 50, minY: 50, maxX: 59, maxY: 59);
      expect(uncoveredTileCount(target, [elsewhere]), 100);
    });

    test('a corner overlap is subtracted once', () {
      final corner = TileRect(minX: 0, minY: 0, maxX: 4, maxY: 4);
      expect(uncoveredTileCount(target, [corner]), 75);
    });

    test('overlapping saved areas are not double counted', () {
      final first = TileRect(minX: 0, minY: 0, maxX: 4, maxY: 4);
      final second = TileRect(minX: 3, minY: 3, maxX: 7, maxY: 7);
      // 25 + 25 - 4 shared = 46 covered.
      expect(uncoveredTileCount(target, [first, second]), 54);
    });

    test('a saved area that swallows the target leaves nothing', () {
      final everything = TileRect(minX: -5, minY: -5, maxX: 20, maxY: 20);
      expect(uncoveredTileCount(target, [everything]), 0);
    });
  });

  group('estimateRegionSize', () {
    final sources = [
      const TileSourceSpec(
        id: 'imagery',
        minZoom: 0,
        maxZoom: 16,
        averageTileBytes: 20000,
      ),
    ];
    final area = box(-76.0, 45.0, -75.5, 45.5);

    test('counts every zoom in the range', () {
      final shallow = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 10,
        sources: sources,
        existing: const [],
      );
      final deep = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 14,
        sources: sources,
        existing: const [],
      );
      expect(deep.totalTiles, greaterThan(shallow.totalTiles));
    });

    test('stops at the zoom the source can actually serve', () {
      final capped = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 20,
        sources: sources,
        existing: const [],
      );
      final atCeiling = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 16,
        sources: sources,
        existing: const [],
      );
      expect(capped.totalTiles, atCeiling.totalTiles);
    });

    test('re-saving the same area at the same detail costs nothing', () {
      final estimate = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 12,
        sources: sources,
        existing: [
          ExistingCoverage(
            sourceIds: const {'imagery'},
            bounds: area,
            minZoom: 5,
            maxZoom: 12,
          ),
        ],
        fixedOverheadBytes: 1000,
      );
      expect(estimate.newTiles, 0);
      expect(estimate.newBytes, 0);
      expect(estimate.overlapsExisting, isTrue);
    });

    test('going deeper than a saved area still costs the extra zooms', () {
      final estimate = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 14,
        sources: sources,
        existing: [
          ExistingCoverage(
            sourceIds: const {'imagery'},
            bounds: area,
            minZoom: 5,
            maxZoom: 12,
          ),
        ],
      );
      expect(estimate.newTiles, greaterThan(0));
      expect(estimate.newBytes, lessThan(estimate.totalBytes));
    });

    test('a saved area of a different basemap does not discount this one', () {
      final estimate = estimateRegionSize(
        bounds: area,
        minZoom: 5,
        maxZoom: 12,
        sources: sources,
        existing: [
          ExistingCoverage(
            sourceIds: const {'something-else'},
            bounds: area,
            minZoom: 5,
            maxZoom: 12,
          ),
        ],
      );
      expect(estimate.newTiles, estimate.totalTiles);
    });

    test('a source is skipped where its bounds do not reach', () {
      final regional = [
        TileSourceSpec(
          id: 'quebec',
          minZoom: 0,
          maxZoom: 14,
          averageTileBytes: 20000,
          bounds: box(-79.9, 44.9, -56.9, 62.7),
        ),
      ];
      final manitoba = box(-96.0, 50.0, -95.5, 50.5);
      final estimate = estimateRegionSize(
        bounds: manitoba,
        minZoom: 5,
        maxZoom: 12,
        sources: regional,
        existing: const [],
      );
      expect(estimate.totalTiles, 0);
    });

    test('a partly overlapping source is charged only for the overlap', () {
      final regional = [
        TileSourceSpec(
          id: 'quebec',
          minZoom: 0,
          maxZoom: 14,
          averageTileBytes: 20000,
          bounds: box(-76.0, 44.0, -70.0, 50.0),
        ),
      ];
      // Half in, half out: the western half is outside the source.
      final straddling = box(-78.0, 45.0, -75.0, 46.0);
      final estimate = estimateRegionSize(
        bounds: straddling,
        minZoom: 10,
        maxZoom: 10,
        sources: regional,
        existing: const [],
      );
      final whole = tileRectFor(straddling, 10).count;
      expect(estimate.totalTiles, greaterThan(0));
      expect(estimate.totalTiles, lessThan(whole));
    });
  });

  group('formatBytes', () {
    test('reads the way a storage screen does', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('kilobytes are whole; a tenth of a kilobyte is noise', () {
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(2048), '2 KB');
    });

    test('drops the decimal once the number is big enough to not need it', () {
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
    });
  });
}
