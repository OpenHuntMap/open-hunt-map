import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

/// Web Mercator tile arithmetic behind the offline basemap size estimate.
///
/// MapLibre reports how big a region turned out only once it has been
/// downloaded, which is far too late to be useful. Everything here exists to
/// answer "roughly how much will this cost me" beforehand, including the part
/// the user cares about most: how much of the area they are about to download
/// they already have.

/// The latitude beyond which Web Mercator stops being defined.
const double _mercatorLimit = 85.05112878;

/// An inclusive rectangle of tile indices at one zoom level.
class TileRect {
  const TileRect({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  int get width => maxX - minX + 1;
  int get height => maxY - minY + 1;
  int get count => width * height;

  TileRect? intersect(TileRect other) {
    final x0 = math.max(minX, other.minX);
    final y0 = math.max(minY, other.minY);
    final x1 = math.min(maxX, other.maxX);
    final y1 = math.min(maxY, other.maxY);
    if (x0 > x1 || y0 > y1) return null;
    return TileRect(minX: x0, minY: y0, maxX: x1, maxY: y1);
  }

  @override
  String toString() => 'TileRect($minX,$minY..$maxX,$maxY)';
}

int _lonToTileX(double lon, int zoom) {
  final n = 1 << zoom;
  final x = ((lon + 180.0) / 360.0 * n).floor();
  return x.clamp(0, n - 1);
}

int _latToTileY(double lat, int zoom) {
  final n = 1 << zoom;
  final clamped = lat.clamp(-_mercatorLimit, _mercatorLimit);
  final radians = clamped * math.pi / 180.0;
  final y =
      ((1.0 - _asinh(math.tan(radians)) / math.pi) / 2.0 * n).floor();
  return y.clamp(0, n - 1);
}

double _asinh(double x) => math.log(x + math.sqrt(x * x + 1.0));

/// The tiles covering [bounds] at [zoom].
///
/// Tile Y runs north to south, so the north edge gives the smallest index.
TileRect tileRectFor(LatLngBounds bounds, int zoom) {
  final west = bounds.southwest.longitude;
  final east = bounds.northeast.longitude;
  final south = bounds.southwest.latitude;
  final north = bounds.northeast.latitude;
  return TileRect(
    minX: _lonToTileX(math.min(west, east), zoom),
    maxX: _lonToTileX(math.max(west, east), zoom),
    minY: _latToTileY(math.max(south, north), zoom),
    maxY: _latToTileY(math.min(south, north), zoom),
  );
}

/// How many tiles of [target] are not inside any of [covered].
///
/// Coordinate compression rather than a per-tile loop: a detailed region can
/// run to millions of tiles, and the caller wants this on every drag of the
/// map. The rectangles are few, so the compressed grid stays tiny.
int uncoveredTileCount(TileRect target, List<TileRect> covered) {
  final clipped = <TileRect>[];
  for (final rect in covered) {
    final overlap = target.intersect(rect);
    if (overlap != null) clipped.add(overlap);
  }
  if (clipped.isEmpty) return target.count;

  final xs = <int>{target.minX, target.maxX + 1};
  final ys = <int>{target.minY, target.maxY + 1};
  for (final rect in clipped) {
    xs.addAll([rect.minX, rect.maxX + 1]);
    ys.addAll([rect.minY, rect.maxY + 1]);
  }
  final xEdges = xs.toList()..sort();
  final yEdges = ys.toList()..sort();

  var uncovered = 0;
  for (var i = 0; i < xEdges.length - 1; i++) {
    for (var j = 0; j < yEdges.length - 1; j++) {
      final x0 = xEdges[i];
      final y0 = yEdges[j];
      final isCovered = clipped.any(
        (rect) =>
            x0 >= rect.minX &&
            x0 <= rect.maxX &&
            y0 >= rect.minY &&
            y0 <= rect.maxY,
      );
      if (!isCovered) {
        uncovered += (xEdges[i + 1] - x0) * (yEdges[j + 1] - y0);
      }
    }
  }
  return uncovered;
}

/// One tile source within a basemap style, as far as the estimator cares.
class TileSourceSpec {
  const TileSourceSpec({
    required this.id,
    required this.minZoom,
    required this.maxZoom,
    required this.averageTileBytes,
    this.bounds,
  });

  final String id;
  final int minZoom;
  final int maxZoom;

  /// Measured, not guessed. See `tools/gis/measure_tile_sizes.py`.
  final int averageTileBytes;

  /// Null means worldwide. A source with bounds still gets downloaded outside
  /// them, because MapLibre ignores source bounds when it walks a region, but
  /// the server answers those requests with an error that costs no storage.
  /// So the estimate counts only the part that overlaps.
  final LatLngBounds? bounds;

  bool covers(LatLngBounds area) {
    final limit = bounds;
    if (limit == null) return true;
    return limit.southwest.longitude <= area.northeast.longitude &&
        limit.northeast.longitude >= area.southwest.longitude &&
        limit.southwest.latitude <= area.northeast.latitude &&
        limit.northeast.latitude >= area.southwest.latitude;
  }
}

/// An area already held offline, for the overlap discount.
class ExistingCoverage {
  const ExistingCoverage({
    required this.sourceIds,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
  });

  final Set<String> sourceIds;
  final LatLngBounds bounds;
  final int minZoom;
  final int maxZoom;
}

/// A size estimate, split so the UI can show what the overlap saved.
class SizeEstimate {
  const SizeEstimate({
    required this.totalBytes,
    required this.newBytes,
    required this.newTiles,
    required this.totalTiles,
  });

  final int totalBytes;
  final int newBytes;
  final int newTiles;
  final int totalTiles;

  int get sharedBytes => totalBytes - newBytes;
  bool get overlapsExisting => newTiles < totalTiles;
}

/// Estimates the download, discounting tiles already held by [existing].
///
/// MapLibre stores each resource once and reference-counts it across regions,
/// so re-downloading an area that overlaps one already saved genuinely costs
/// only the new tiles. [SizeEstimate.newBytes] is therefore the number that
/// belongs next to "space needed"; [SizeEstimate.totalBytes] is what the area
/// occupies in total.
SizeEstimate estimateRegionSize({
  required LatLngBounds bounds,
  required int minZoom,
  required int maxZoom,
  required List<TileSourceSpec> sources,
  required List<ExistingCoverage> existing,
  int fixedOverheadBytes = 0,
}) {
  var totalBytes = 0;
  var newBytes = 0;
  var totalTiles = 0;
  var newTiles = 0;

  for (final source in sources) {
    if (!source.covers(bounds)) continue;
    final from = math.max(minZoom, source.minZoom);
    final to = math.min(maxZoom, source.maxZoom);
    for (var zoom = from; zoom <= to; zoom++) {
      var rect = tileRectFor(bounds, zoom);
      final limit = source.bounds;
      if (limit != null) {
        final clipped = rect.intersect(tileRectFor(limit, zoom));
        if (clipped == null) continue;
        rect = clipped;
      }
      final covered = <TileRect>[
        for (final region in existing)
          if (region.sourceIds.contains(source.id) &&
              zoom >= region.minZoom &&
              zoom <= region.maxZoom)
            tileRectFor(region.bounds, zoom),
      ];
      final fresh = uncoveredTileCount(rect, covered);
      totalTiles += rect.count;
      newTiles += fresh;
      totalBytes += rect.count * source.averageTileBytes;
      newBytes += fresh * source.averageTileBytes;
    }
  }

  // Glyphs, sprites and the style itself. Charged only when something is
  // actually being downloaded, and only once: a second region reuses them.
  final overhead = existing.isEmpty ? fixedOverheadBytes : 0;
  return SizeEstimate(
    totalBytes: totalBytes + fixedOverheadBytes,
    newBytes: newTiles == 0 ? 0 : newBytes + overhead,
    newTiles: newTiles,
    totalTiles: totalTiles,
  );
}

/// Bytes as a short human string. Binary units, matching what Android's
/// storage settings report, so the two do not appear to disagree.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
