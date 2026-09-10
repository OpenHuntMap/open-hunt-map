import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:open_woods_map/map/basemap.dart';
import 'package:open_woods_map/offline/area_picker_page.dart';
import 'package:open_woods_map/offline/basemap_area_store.dart';

LatLngBounds box(double west, double south, double east, double north) =>
    LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );

BasemapArea area({
  required int regionId,
  BasemapKind basemap = BasemapKind.satellite,
  LatLngBounds? bounds,
  int maxZoom = 14,
  bool complete = true,
}) =>
    BasemapArea(
      regionId: regionId,
      name: 'Area $regionId',
      basemap: basemap,
      bounds: bounds ?? box(-76.0, 45.0, -75.5, 45.5),
      minZoom: 5,
      maxZoom: maxZoom,
      sourceIds: const {'on-ortho'},
      sizeBytes: 1024,
      complete: complete,
    );

void main() {
  group('AreaDetail.forMaxZoom', () {
    test('an area saved at a level reopens on that level', () {
      expect(AreaDetail.forMaxZoom(12), AreaDetail.overview);
      expect(AreaDetail.forMaxZoom(14), AreaDetail.standard);
      expect(AreaDetail.forMaxZoom(16), AreaDetail.detailed);
    });

    // Streets tops out at z14, so a Detailed pick is saved as 14 and comes back
    // as Standard. Rounding the other way would offer detail that is not there.
    test('a ceiling between two levels rounds down', () {
      expect(AreaDetail.forMaxZoom(15), AreaDetail.standard);
      expect(AreaDetail.forMaxZoom(13), AreaDetail.overview);
    });

    test('anything shallower than the lowest level is Overview', () {
      expect(AreaDetail.forMaxZoom(5), AreaDetail.overview);
      expect(AreaDetail.forMaxZoom(0), AreaDetail.overview);
    });

    test('a ceiling past the deepest level is Detailed', () {
      expect(AreaDetail.forMaxZoom(20), AreaDetail.detailed);
    });
  });

  group('coverageForEstimate', () {
    test('a complete area discounts a new download', () {
      final saved = [area(regionId: 1)];
      expect(coverageForEstimate(saved), hasLength(1));
    });

    test('an interrupted area is not counted as coverage', () {
      final saved = [area(regionId: 1, complete: false)];
      expect(coverageForEstimate(saved), isEmpty);
    });

    // The replacement downloads while the old region is still on disk, so its
    // tiles are reused. Discounting them is what makes an edit that shrinks an
    // area, or lowers its detail, report the nothing-to-fetch that it costs.
    test('the area being edited discounts its own replacement', () {
      final target = area(regionId: 1);
      final coverage = coverageForEstimate([target]);
      expect(coverage, hasLength(1));
      expect(coverage.single.bounds.southwest, target.bounds.southwest);
    });

    test('an interrupted area is skipped while the others still count', () {
      final partial = area(regionId: 1, complete: false);
      final other = area(regionId: 2);
      final coverage = coverageForEstimate([partial, other]);
      expect(coverage, hasLength(1));
      expect(coverage.single.bounds.southwest, other.bounds.southwest);
    });
  });

  group('areaSupersedes', () {
    final saved = area(
      regionId: 1,
      bounds: box(-76.0, 45.0, -75.5, 45.5),
      maxZoom: 14,
    );

    test('the same definition supersedes itself', () {
      expect(
        areaSupersedes(
          saved,
          basemap: saved.basemap,
          bounds: saved.bounds,
          maxZoom: saved.maxZoom,
        ),
        isTrue,
      );
    });

    test('growing the extent and the detail supersedes', () {
      expect(
        areaSupersedes(
          saved,
          basemap: saved.basemap,
          bounds: box(-76.5, 44.5, -75.0, 46.0),
          maxZoom: 16,
        ),
        isTrue,
      );
    });

    test('shrinking any edge does not', () {
      expect(
        areaSupersedes(
          saved,
          basemap: saved.basemap,
          bounds: box(-76.0, 45.0, -75.6, 45.5),
          maxZoom: 14,
        ),
        isFalse,
      );
    });

    test('dropping the detail level does not', () {
      expect(
        areaSupersedes(
          saved,
          basemap: saved.basemap,
          bounds: saved.bounds,
          maxZoom: 12,
        ),
        isFalse,
      );
    });

    test('a different basemap does not, whatever the extent', () {
      expect(
        areaSupersedes(
          saved,
          basemap: BasemapKind.hybrid,
          bounds: box(-80.0, 40.0, -70.0, 50.0),
          maxZoom: 16,
        ),
        isFalse,
      );
    });
  });
}
