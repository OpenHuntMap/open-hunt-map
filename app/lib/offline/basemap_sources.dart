import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';

import '../map/basemap.dart';
import 'tile_math.dart';

/// What each basemap is made of, for the offline size estimate and for pruning
/// the style handed to the downloader.

/// Median bytes per tile, measured against the live endpoints by
/// `tools/gis/measure_tile_sizes.py` over a spread of city, farmland and bush
/// samples in Ontario and Quebec. Medians rather than means: a handful of dense
/// urban tiles drag the mean far above anything a hunting pack contains.
///
/// Re-run the script and update these if a source changes.
const Map<String, int> _averageTileBytes = {
  'openmaptiles': 55 * 1024,
  'sentinel2': 14 * 1024,
  'on-ortho': 22 * 1024,
  'qc-ortho': 13 * 1024,
  'ne2_shaded': 8 * 1024,
};

/// Used when a style names a source this table has never seen. Deliberately on
/// the high side so a new source shows up as expensive rather than free.
const int _unknownTileBytes = 40 * 1024;

/// Zoom ceilings that live in a source's TileJSON rather than in the style, so
/// they cannot be read from the bundled asset.
const Map<String, int> _maxZoomFromTileJson = {
  'openmaptiles': 14,
  'ne2_shaded': 6,
};

/// Glyph ranges, sprite sheets and the style document. Charged once per
/// device rather than per area, and only for styles that draw labels.
const int _labelledStyleOverheadBytes = 3 * 1024 * 1024;

/// The most detail an area can be saved at.
///
/// Imagery quadruples in size per level and the provincial orthophotography
/// runs to z19/z20, which would let someone start a download measured in tens
/// of gigabytes by accident.
const int maxOfflineZoom = 16;

/// The floor for every saved area. Zoomed-out tiles are so few that including
/// them is free, and without them the map goes blank the moment the user pinches
/// out past the area they saved.
const int minOfflineZoom = 5;

/// Liberty's sources, which cannot be read from a bundled asset because the
/// style itself is fetched from OpenFreeMap.
///
/// Mirrors https://tiles.openfreemap.org/styles/liberty. `libertySourcesMatch`
/// in the tests checks this against the live style.
const List<String> libertySourceIds = ['openmaptiles', 'ne2_shaded'];

/// Parses the tile sources of a style document.
List<TileSourceSpec> sourceSpecsFromStyle(String styleJson) {
  final style = json.decode(styleJson) as Map<String, dynamic>;
  final sources = (style['sources'] as Map<String, dynamic>?) ?? const {};
  final specs = <TileSourceSpec>[];
  sources.forEach((id, raw) {
    final source = raw as Map<String, dynamic>;
    final type = source['type'] as String?;
    if (type != 'raster' && type != 'vector') return;
    specs.add(
      TileSourceSpec(
        id: id,
        minZoom: (source['minzoom'] as num?)?.toInt() ?? 0,
        maxZoom: (source['maxzoom'] as num?)?.toInt() ??
            _maxZoomFromTileJson[id] ??
            maxOfflineZoom,
        averageTileBytes: _averageTileBytes[id] ?? _unknownTileBytes,
        bounds: _boundsFrom(source['bounds']),
      ),
    );
  });
  return specs;
}

/// The sources of a basemap whose style is not bundled.
List<TileSourceSpec> remoteSourceSpecs(BasemapKind kind) {
  if (kind != BasemapKind.streets) return const [];
  return [
    for (final id in libertySourceIds)
      TileSourceSpec(
        id: id,
        minZoom: 0,
        maxZoom: _maxZoomFromTileJson[id] ?? maxOfflineZoom,
        averageTileBytes: _averageTileBytes[id] ?? _unknownTileBytes,
      ),
  ];
}

/// Whether a basemap's style draws labels, and so pays the glyph overhead.
int overheadBytesFor(Iterable<TileSourceSpec> sources) =>
    sources.any((source) => source.id == 'openmaptiles')
        ? _labelledStyleOverheadBytes
        : 0;

/// The highest zoom worth offering for a basemap. Never above [maxOfflineZoom],
/// and never above what every source can actually serve.
int detailCeilingFor(Iterable<TileSourceSpec> sources) {
  if (sources.isEmpty) return maxOfflineZoom;
  final best = sources.map((source) => source.maxZoom).reduce(
        (a, b) => a > b ? a : b,
      );
  return best < maxOfflineZoom ? best : maxOfflineZoom;
}

LatLngBounds? _boundsFrom(Object? raw) {
  if (raw is! List || raw.length < 4) return null;
  final values = raw.map((value) => (value as num).toDouble()).toList();
  return LatLngBounds(
    southwest: LatLng(values[1], values[0]),
    northeast: LatLng(values[3], values[2]),
  );
}

/// Rewrites a style so it only names the sources that reach [area], and drops
/// the layers that used them.
///
/// MapLibre walks every source in a style when it downloads a region and
/// ignores each source's `bounds` while doing it, so an area in Ontario would
/// otherwise spend the whole download asking Quebec's imagery server for tiles
/// it does not have. Pruning first keeps the request count honest and keeps us
/// off a provincial server that owes us nothing.
String pruneStyleToArea(String styleJson, LatLngBounds area) {
  final style = json.decode(styleJson) as Map<String, dynamic>;
  final sources = (style['sources'] as Map<String, dynamic>?) ?? const {};
  final keep = <String, dynamic>{};
  for (final spec in sourceSpecsFromStyle(styleJson)) {
    if (spec.covers(area)) keep[spec.id] = sources[spec.id];
  }
  // Non-tile sources, such as the flat background, carry no bounds and cost
  // nothing to keep.
  sources.forEach((id, source) {
    final type = (source as Map<String, dynamic>)['type'];
    if (type != 'raster' && type != 'vector') keep[id] = source;
  });

  final layers = (style['layers'] as List<dynamic>? ?? const [])
      .where((layer) {
        final source = (layer as Map<String, dynamic>)['source'] as String?;
        return source == null || keep.containsKey(source);
      })
      .toList();

  return json.encode({...style, 'sources': keep, 'layers': layers});
}
