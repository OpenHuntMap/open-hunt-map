import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';

class OverlayController extends ChangeNotifier {
  OverlayController({Map<String, bool>? initialVisibility})
      : visibility = initialVisibility ??
            {
              for (final id in layerOrder) id: true,
            };

  static const layerOrder = [
    'crown_land',
    // Directly above the tenure it qualifies. Not a closure and not separate
    // land: the same Crown parcel, with somebody else's lease on it.
    'crown_disposition',
    'municipal_forest',
    'conservation_authority',
    'first_nations',
    'parks',
    // Beside the parks it shares an Act with, and above them so the outline of a
    // reserve inside a park stays readable.
    'conservation_reserve',
    // Above the tenure layers: these close ground they show as open.
    'game_preserve',
    'federal_closure',
    'defence_land',
    'land_use_plan',
    'wmu',
    'sunday_gun',
    'municipalities',
  ];

  static const _colorPrefKey = 'overlay.colors';

  final Map<String, bool> visibility;
  final Map<String, String> _colorOverrides = {};
  MapLibreMapController? _map;
  Map<String, LoadedLayer> _layers = const {};
  final Set<String> _added = {};

  Map<String, LoadedLayer> get layers => _layers;

  /// Colours the user can pick from. Deliberately saturated mid-tones: they have
  /// to stay legible both on the pale offline basemap and on satellite imagery,
  /// where dark greens and blues disappear into forest and water.
  static const palette = <String>[
    '#FFB300',
    '#FF6D00',
    '#D50000',
    '#C2185B',
    '#6A1B9A',
    '#3949AB',
    '#0288D1',
    '#00B8D4',
    '#00897B',
    '#2E7D32',
    '#827717',
    '#4E342E',
    '#37474F',
    '#FAFAFA',
  ];

  static String defaultColorFor(String id) => _styles[id]?.color ?? '#2E7D32';

  /// The fill opacity a parcel of [id] is drawn at, given its `basis`.
  ///
  /// Exposed so the "less known, less ink" rule can be asserted: it is the only
  /// thing on the map itself that distinguishes Crown land a policy covers from
  /// Crown land the province has said nothing specific about.
  static double fillOpacityFor(String id, {String? basis}) {
    final style = _styles[id];
    if (style == null) return 0.0;
    return style.fillOpacityByBasis[basis] ?? style.fillOpacity;
  }

  String colorFor(String id) =>
      _colorOverrides[id] ?? defaultColorFor(id);

  bool isCustomColor(String id) => _colorOverrides.containsKey(id);

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_colorPrefKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        if (_styles.containsKey(entry.key)) {
          _colorOverrides[entry.key] = entry.value.toString();
        }
      }
    } catch (_) {
      // A corrupt preference is not worth failing startup over.
    }
    notifyListeners();
  }

  /// Pass a null [hex] to go back to the layer's default colour.
  Future<void> setColor(String id, String? hex) async {
    if (hex == null) {
      _colorOverrides.remove(id);
    } else {
      _colorOverrides[id] = hex;
    }
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (_colorOverrides.isEmpty) {
      await prefs.remove(_colorPrefKey);
    } else {
      await prefs.setString(_colorPrefKey, jsonEncode(_colorOverrides));
    }

    final map = _map;
    if (map == null || !_added.contains(id)) return;
    final style = _styles[id]!;
    final visible = visibility[id] == true;
    await map.setLayerProperties(_fillId(id), _fill(id, style, visible));
    await map.setLayerProperties(_lineId(id), _line(id, style, visible));
  }

  Future<void> attach(
    MapLibreMapController map,
    Map<String, LoadedLayer> layers,
  ) async {
    _map = map;
    await replaceLayers(layers);
  }

  Future<void> replaceLayers(Map<String, LoadedLayer> layers) async {
    final map = _map;
    if (map == null) {
      _layers = layers;
      return;
    }
    for (final id in _added.toList().reversed) {
      // A style reload drops the layers underneath us, so removal is
      // best-effort rather than a reason to fail the whole attach.
      for (final removal in [
        () => map.removeLayer(_fillId(id)),
        () => map.removeLayer(_lineId(id)),
        () => map.removeSource(_sourceId(id)),
      ]) {
        try {
          await removal();
        } catch (_) {}
      }
    }
    _added.clear();
    _layers = layers;
    for (final id in layerOrder) {
      final layer = layers[id];
      if (layer == null) continue;
      await _addLayer(map, id, layer);
      _added.add(id);
    }
  }

  Future<void> setVisible(String id, bool value) async {
    visibility[id] = value;
    notifyListeners();
    final map = _map;
    if (map == null || !_added.contains(id)) return;
    final style = _styles[id]!;
    if (style.alwaysQueryable) {
      // Dropped to zero opacity rather than hidden: MapLibre only hit-tests
      // layers it still renders, and Land Info resolves WMU and municipality
      // whatever the toggles say.
      await map.setLayerProperties(_fillId(id), _fill(id, style, value));
      await map.setLayerProperties(_lineId(id), _line(id, style, value));
    } else {
      await map.setLayerVisibility(_fillId(id), value);
      await map.setLayerVisibility(_lineId(id), value);
    }
  }

  /// Layers a tap should be resolved against, in draw order.
  Iterable<String> get identifiableLayerIds => layerOrder.where(
        (id) =>
            _added.contains(id) &&
            (visibility[id] == true || _styles[id]!.alwaysQueryable),
      );

  String fillLayerId(String id) => _fillId(id);

  Future<void> _addLayer(
    MapLibreMapController map,
    String id,
    LoadedLayer layer,
  ) async {
    final style = _styles[id]!;
    final visible = visibility[id] == true;
    await map.addSource(
      _sourceId(id),
      // A path, not the parsed collection: MapLibre reads and tiles the file
      // natively, which keeps 40k-parcel layers off the Dart and Android heaps.
      GeojsonSourceProperties(data: layer.sourceUri),
    );
    await map.addFillLayer(_sourceId(id), _fillId(id), _fill(id, style, visible));
    await map.addLineLayer(_sourceId(id), _lineId(id), _line(id, style, visible));
  }

  /// Layers kept in the style purely so they stay queryable are drawn at zero
  /// opacity; everything else keeps its paint and toggles `visibility`.
  bool _paintedOut(_OverlayStyle style, bool visible) =>
      !visible && style.alwaysQueryable;

  FillLayerProperties _fill(String id, _OverlayStyle style, bool visible) =>
      FillLayerProperties(
        fillColor: colorFor(id),
        fillOpacity:
            _paintedOut(style, visible) ? 0.0 : _fillOpacityFor(style),
        visibility: visible || style.alwaysQueryable ? 'visible' : 'none',
      );

  /// A plain number, or a MapLibre `case` expression where the layer draws some
  /// of its parcels fainter than others.
  Object _fillOpacityFor(_OverlayStyle style) {
    if (style.fillOpacityByBasis.isEmpty) return style.fillOpacity;
    return <Object>[
      'case',
      for (final entry in style.fillOpacityByBasis.entries) ...[
        ['==', ['get', 'basis'], entry.key],
        entry.value,
      ],
      style.fillOpacity,
    ];
  }

  LineLayerProperties _line(String id, _OverlayStyle style, bool visible) =>
      LineLayerProperties(
        lineColor: colorFor(id),
        lineWidth: style.lineWidth,
        lineOpacity: _paintedOut(style, visible) ? 0.0 : 0.95,
        visibility: visible || style.alwaysQueryable ? 'visible' : 'none',
      );

  String _sourceId(String id) => 'ohm-source-$id';
  String _fillId(String id) => 'ohm-fill-$id';
  String _lineId(String id) => 'ohm-line-$id';
}

class _OverlayStyle {
  const _OverlayStyle(
    this.color,
    this.fillOpacity,
    this.lineWidth, {
    this.alwaysQueryable = false,
    this.fillOpacityByBasis = const {},
  });

  final String color;
  final double fillOpacity;
  final double lineWidth;

  /// Fill opacity for particular `basis` values, where how much the app knows
  /// about a parcel varies within one layer. Everything unlisted takes
  /// [fillOpacity].
  ///
  /// Opacity rather than colour because MapLibre supports data-driven
  /// `fill-opacity` on Android and iOS, and because the alternative the project
  /// would reach for first is not available: `line-dasharray` is documented
  /// data-driven on the web only, so per-feature dashes cannot be done in one
  /// layer on mobile.
  final Map<String, double> fillOpacityByBasis;

  /// Land Info needs this layer for seasons or by-laws even when the user has
  /// switched its outline off.
  final bool alwaysQueryable;
}

/// Defaults are tuned for the satellite basemap, which is the hard case: over
/// Ontario bush, a green polygon on green forest is invisible. Warm saturated
/// hues carry against both forest and the pale offline basemap, and the outlines
/// are wide enough to read when the fill is faint.
const _styles = <String, _OverlayStyle>{
  // Half of Ontario's Crown land by area has no land use policy on it, and the
  // app has to stop drawing that identically to the half a policy actually
  // covers. Same amber either way — it is all Crown land, and a second colour
  // would imply a second kind of tenure — but the parcels the province has said
  // nothing specific about get less ink, because less is known about them.
  'crown_land': _OverlayStyle(
    '#FFB300',
    0.30,
    1.8,
    fillOpacityByBasis: {'tenure_only': 0.15},
  ),
  // Violet, and deliberately not from the red end: the occupier of a lease can
  // refuse you entry, but no wildlife law closes this ground, and borrowing the
  // colour of a game preserve would say the wrong thing. It has to carry over
  // the amber it sits on, so it is the outline that does the work and the fill
  // stays light enough to read the Crown parcel underneath. Always queryable:
  // a hunt camp is small, easy to pan past, and the price of missing one is
  // walking into somebody's yard with a rifle.
  'crown_disposition':
      _OverlayStyle('#AA00FF', 0.16, 2.2, alwaysQueryable: true),
  // Real parcel boundaries from provincial records, so drawn solid like Crown
  // tenure. The gaps between tracts are private land.
  'municipal_forest': _OverlayStyle('#00B8D4', 0.28, 1.8),
  // Neither open nor closed: this land needs the authority's permit. Orange
  // rather than red so it reads as stop-and-ask instead of no, and distinct from
  // the municipal forest it often adjoins. Always queryable, because these
  // properties are small enough to miss and the price of missing one is trespass.
  'conservation_authority':
      _OverlayStyle('#FF6D00', 0.30, 1.8, alwaysQueryable: true),
  // Neutral rather than warning-coloured on purpose. This is a different
  // jurisdiction, not a wildlife closure, and white is the one hue that stays
  // legible over both bush and the pale offline basemap without borrowing the
  // vocabulary of a prohibition.
  'first_nations': _OverlayStyle('#FAFAFA', 0.22, 2.0, alwaysQueryable: true),
  'parks': _OverlayStyle('#3949AB', 0.26, 1.6),
  // Deliberately the parks hue one step lighter, and not a colour of its own.
  // The kinship is real — same Act, same agency, adjacent designations — and the
  // difference in rule is the opposite of what a warmer or cooler hue would
  // suggest, so the card carries it instead of the map. The fill stays faint
  // because the job here is naming the designation, not shading ground as
  // restricted, which is exactly what this layer says it is not.
  'conservation_reserve': _OverlayStyle('#5C6BC0', 0.18, 1.8),
  // The two wildlife closures share the red end of the palette, since they are
  // the ones you would otherwise be hunting, but keep separate hues: one is
  // enforced by a provincial officer and the other by a federal one, and the map
  // has to be able to say which.
  'game_preserve': _OverlayStyle('#D50000', 0.32, 2.0, alwaysQueryable: true),
  'federal_closure':
      _OverlayStyle('#C2185B', 0.32, 2.0, alwaysQueryable: true),
  // Also a closure, but a different kind: it is closed because it is a base,
  // not because of the wildlife, and slate keeps it from reading as one more
  // hunting restriction at a glance.
  'defence_land': _OverlayStyle('#37474F', 0.32, 2.0, alwaysQueryable: true),
  // Context, not tenure, so it is drawn almost to nothing and kept queryable:
  // its job is to let the card tell "the atlas never reached here" apart from
  // "no policy applies here", which is a distinction the user has to be told
  // whether or not they asked to see the outline.
  'land_use_plan': _OverlayStyle('#00897B', 0.01, 1.2, alwaysQueryable: true),
  'wmu': _OverlayStyle('#6A1B9A', 0.02, 3.2, alwaysQueryable: true),
  // Covers most of settled southern Ontario, so the fill stays faint enough to
  // read the tenure layers through. Queryable with the toggle off because the
  // answer matters most where no polygon is drawn: outside these boundaries and
  // south of the French and Mattawa rivers, Sunday gun hunting is an offence.
  'sunday_gun': _OverlayStyle('#0288D1', 0.08, 1.2, alwaysQueryable: true),
  'municipalities': _OverlayStyle('#4E342E', 0.01, 1.4, alwaysQueryable: true),
};
