import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/province_loader.dart';
import '../offline/basemap_area_store.dart';
import '../offline/offline_page.dart';
import '../search/coordinate_search_sheet.dart';
import '../tracks/follow_bar.dart';
import '../tracks/track_follow.dart';
import '../tracks/track_math.dart';
import '../tracks/track_style.dart';
import '../waypoints/waypoint_category.dart';
import '../waypoints/waypoint_store.dart';
import '../waypoints/waypoints_page.dart';
import 'basemap.dart';
import 'basemap_panel.dart';
import 'land_info.dart';
import 'land_info_sheet.dart';
import 'layer_panel.dart';
import 'overlay_controller.dart';

class MapShell extends StatefulWidget {
  const MapShell({super.key});

  @override
  State<MapShell> createState() => _MapShellState();
}

class _MapShellState extends State<MapShell> {
  static const _ottawa = LatLng(45.1, -75.75);
  static const _sampleZoom = 11.5;
  static const _myLocationZoom = 14.0;

  /// Closer in than a location fix, because the user picked this point out of a
  /// list and wants to see what is around it rather than where it is.
  static const _waypointRevealZoom = 15.0;
  static const _landInfoTipDismissedKey = 'land_info_tip_dismissed';
  static const _trackArrowsKey = 'tracks.arrows';

  final _loader = ProvinceLoader();
  final _overlays = OverlayController();
  final _waypoints = WaypointStore();

  /// The SDF glyphs, kept so a basemap swap does not re-read fifteen assets.
  final _iconBytes = <String, Uint8List>{};

  /// Whether the glyphs are in the *current* style. Reset on every style load.
  var _iconsRegistered = false;

  MapLibreMapController? _map;
  List<Province> _provinces = const [];
  ProvinceData? _provinceData;
  String _provinceId = 'on';

  /// Where the camera is now, kept whole rather than as a bare target: a
  /// basemap swap tears the map widget down and rebuilds it, and the zoom and
  /// bearing have to survive that or the user loses the spot they switched
  /// basemaps to look at.
  CameraPosition _camera = const CameraPosition(
    target: _ottawa,
    zoom: _sampleZoom,
  );

  /// The province the map has been framed on. Null until the first style loads,
  /// which is how a first run is told apart from a basemap swap.
  String? _framedProvince;

  /// Whether the map was built already looking at the user, in which case the
  /// first style load must not re-frame it on the province.
  bool _openedOnUser = false;
  LatLng? _identifiedLocation;

  /// The tap being resolved, so the duplicate MapLibre sends for the same tap is
  /// dropped rather than racing it. See [_identify].
  math.Point<double>? _identifying;
  String? _error;
  bool _styleReady = false;

  /// Saved basemap areas being outlined on the map, and which one the user asked
  /// to see. Empty unless they came back from Offline packs asking.
  List<BasemapArea> _offlineAreas = const [];
  BasemapArea? _highlightedArea;
  BasemapKind _basemap = BasemapKind.streets;
  final Map<BasemapKind, String> _styleCache = {};
  int _mapEpoch = 0;
  bool _locating = false;
  bool _recording = false;
  bool _needsPack = false;
  bool _showLandInfoTip = false;
  bool _myLocationEnabled = false;
  StreamSubscription<Position>? _positionSubscription;
  final List<TrackPoint> _activeTrack = [];

  /// Fixes discarded during the current recording for being too imprecise.
  /// Reported on save; see [_worstUsableAccuracyMetres].
  var _rejectedFixes = 0;

  /// The track being followed, or null when not following one.
  Waypoint? _followTrack;
  var _followReversed = false;

  /// [_followTrack]'s points in the direction being walked, with their running
  /// distances. Held rather than recomputed because both are wanted on every
  /// fix and a long track has thousands of points.
  List<TrackPoint> _followPoints = const [];
  List<double> _followCumulative = const [];
  FollowGuidance? _followGuidance;

  /// The last fix seen, so reversing direction can re-answer immediately instead
  /// of leaving the bar blank until the next one arrives.
  Position? _lastPosition;

  /// Whether arriving at the end has already been announced, so it is said once
  /// rather than on every fix for as long as someone stands there.
  var _arrivalAnnounced = false;

  /// Arrows on by default: a track without them says where it went but not which
  /// way, and which way is the whole point of following one back out.
  final _trackArrows = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    _trackArrows.addListener(_applyTrackArrows);
    _bootstrap();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _trackArrows.removeListener(_applyTrackArrows);
    _trackArrows.dispose();
    super.dispose();
  }

  /// Redraws both track layers, rather than hiding an arrow layer that may not
  /// have been added: the sync methods drop and rebuild, so off simply means the
  /// arrow layer is never created.
  Future<void> _applyTrackArrows() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_trackArrowsKey, _trackArrows.value);
    await _syncSavedTrackSource();
    await _syncFollowSource();
  }

  Future<void> _bootstrap() async {
    try {
      // Started before the assets so the fix overlaps with the file reads.
      // Resolving it here rather than animating after the style loads is what
      // makes opening on the user reliable: the map is *built* looking at the
      // right place, so there is no animation to lose a race with the map's own
      // initialisation.
      final launchFix = _resolveLaunchLocation();
      final offline = await rootBundle.loadString('assets/styles/offline.json');
      final satellite = await rootBundle.loadString(
        'assets/styles/satellite.json',
      );
      final hybrid = await rootBundle.loadString('assets/styles/hybrid.json');
      final provinces = await _loader.loadProvinces();
      await _waypoints.load();
      await _overlays.loadPreferences();
      final prefs = await SharedPreferences.getInstance();
      final tipDismissed = prefs.getBool(_landInfoTipDismissedKey) ?? false;
      // Read before the style loads, so the first draw already honours it rather
      // than drawing arrows and then taking them away.
      _trackArrows.value = prefs.getBool(_trackArrowsKey) ?? true;
      final fix = await launchFix;
      if (!mounted) return;
      setState(() {
        _styleCache[BasemapKind.offline] = offline;
        _styleCache[BasemapKind.satellite] = satellite;
        _styleCache[BasemapKind.hybrid] = hybrid;
        _provinces = provinces;
        _showLandInfoTip = !tipDismissed;
        // This setState is the one that lets the map build, so setting the
        // camera here means the very first frame is already on the user.
        if (fix != null) {
          _camera = CameraPosition(target: fix, zoom: _myLocationZoom);
          _openedOnUser = true;
          _myLocationEnabled = true;
        }
      });
      await _loadProvinceData(_provinceId);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Could not start the map.\n$error',
        );
      }
    }
  }

  /// Province overlays live only in downloadable packs, so "not installed" is
  /// the expected first-run state rather than a failure.
  Future<void> _loadProvinceData(String id) async {
    try {
      final data = await _loader.loadProvince(id);
      if (!mounted || id != _provinceId) return;
      setState(() {
        _provinceData = data;
        _needsPack = false;
        _error = null;
      });
      await _overlays.replaceLayers(data.layers);
    } on PackNotInstalled {
      if (!mounted || id != _provinceId) return;
      setState(() {
        _provinceData = null;
        _needsPack = true;
        _error = null;
      });
      await _overlays.replaceLayers(const {});
    } catch (error) {
      if (!mounted || id != _provinceId) return;
      setState(() => _error = 'Could not load $id data: $error');
    }
  }

  Future<void> _openOfflinePacks() async {
    final shown = await Navigator.push<OfflineAreaReveal>(
      context,
      MaterialPageRoute(
        builder: (_) => OfflinePage(camera: _camera, basemap: _basemap),
      ),
    );
    if (!mounted) return;
    await _loadProvinceData(_provinceId);
    if (shown != null && mounted) await _revealOfflineAreas(shown);
  }

  /// Outlines every saved basemap area and frames the one the user asked about.
  ///
  /// A name in a list says nothing about where the tiles actually are, which
  /// stops being a small problem once there are several saved areas.
  Future<void> _revealOfflineAreas(OfflineAreaReveal reveal) async {
    setState(() {
      _offlineAreas = reveal.areas;
      _highlightedArea = reveal.focus;
    });
    await _syncOfflineAreaSource();
    final map = _map;
    if (map == null) return;
    await map.animateCamera(
      CameraUpdate.newLatLngBounds(
        reveal.focus.bounds,
        left: 24,
        right: 24,
        top: 24,
        bottom: 24,
      ),
    );
  }

  Future<void> _clearOfflineAreas() async {
    setState(() {
      _offlineAreas = const [];
      _highlightedArea = null;
    });
    await _syncOfflineAreaSource();
  }

  Future<void> _syncOfflineAreaSource() async {
    final map = _map;
    if (map == null || !_styleReady) return;

    try {
      await map.removeLayer('owm-offline-area-lines');
    } catch (_) {}
    try {
      await map.removeSource('owm-offline-areas');
    } catch (_) {}
    if (_offlineAreas.isEmpty) return;

    final focus = _highlightedArea;
    final features = <Map<String, dynamic>>[];
    for (final area in _offlineAreas) {
      final sw = area.bounds.southwest;
      final ne = area.bounds.northeast;
      features.add({
        'type': 'Feature',
        'properties': {
          'name': area.name,
          // Data-driven width, so the area the user tapped reads as the answer
          // to their question and the rest stay as context.
          'width': area.regionId == focus?.regionId ? 3.4 : 1.4,
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [sw.longitude, sw.latitude],
            [ne.longitude, sw.latitude],
            [ne.longitude, ne.latitude],
            [sw.longitude, ne.latitude],
            [sw.longitude, sw.latitude],
          ],
        },
      });
    }

    await map.addSource(
      'owm-offline-areas',
      GeojsonSourceProperties(
        data: {'type': 'FeatureCollection', 'features': features},
      ),
    );
    await map.addLineLayer(
      'owm-offline-areas',
      'owm-offline-area-lines',
      // Lime, and solid. Every tenure colour is taken, and dashes are reserved
      // for "this boundary is approximate", which a download footprint is not.
      const LineLayerProperties(
        lineColor: '#76FF03',
        lineWidth: [Expressions.get, 'width'],
      ),
    );
  }

  String get _styleString {
    final remote = _basemap.remoteStyleUrl;
    if (remote != null) return remote;
    return _styleCache[_basemap] ?? _styleCache[BasemapKind.offline] ?? '{}';
  }

  String get _provinceCode => _provinceId.toUpperCase();

  Province? get _selectedProvince {
    for (final province in _provinces) {
      if (province.id == _provinceId) return province;
    }
    return null;
  }

  /// Spells out what is and is not real yet for a province still in preview.
  Future<void> _showProvinceStatus() async {
    final province = _selectedProvince;
    if (province == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${province.name} — preview'),
        content: Text(
          province.statusNote ??
              'Data for this province is still incomplete. Verify against '
                  'official sources.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  bool get _stylesReady =>
      _styleCache.containsKey(BasemapKind.offline) &&
      _styleCache.containsKey(BasemapKind.satellite) &&
      _styleCache.containsKey(BasemapKind.hybrid);

  /// The loaded province, as a chip rather than a bare `DropdownButton`.
  ///
  /// A two-letter code needs to look like something you can press. The outline
  /// and the padding say that, and they buy a tap target the size of the icon
  /// buttons beside it instead of the width of the word "ON".
  Widget _provinceSelector() => PopupMenuButton<String>(
    tooltip: 'Province',
    position: PopupMenuPosition.under,
    color: const Color(0xFFFFFBF0),
    onSelected: _selectProvince,
    itemBuilder: (context) => _provinces
        .map(
          (province) => PopupMenuItem(
            value: province.id,
            child: Row(
              children: [
                Icon(
                  province.id == _provinceId
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 18,
                  color: const Color(0xFF1B5E20),
                ),
                const SizedBox(width: 10),
                Text(province.name),
                if (province.isPreview) ...[
                  const SizedBox(width: 6),
                  const Text(
                    'preview',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ],
            ),
          ),
        )
        .toList(),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white54),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _selectedProvince?.code ?? '--',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down, color: Colors.white, size: 20),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // No wordmark. On a phone the bar is the scarcest space in the app and
        // the user already knows which app they opened. What belongs here is the
        // one thing that changes what everything below it means: which
        // province's data is loaded.
        titleSpacing: 8,
        title: Row(
          children: [
            if (_provinces.isNotEmpty) _provinceSelector(),
            if (_selectedProvince?.isPreview == true) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: _showProvinceStatus,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFC107),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'PREVIEW',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Color(0xFF3E2C00),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Go to a coordinate',
            icon: const Icon(Icons.search),
            onPressed: _searchCoordinate,
          ),
          IconButton(
            tooltip: 'Basemap: ${_basemap.label}',
            icon: Icon(_basemap.icon),
            onPressed: _pickBasemap,
          ),
          IconButton(
            tooltip: 'Layers',
            icon: const Icon(Icons.layers),
            onPressed: _showLayers,
          ),
          IconButton(
            tooltip: 'Waypoints',
            icon: const Icon(Icons.location_on_outlined),
            onPressed: _showWaypoints,
          ),
          IconButton(
            tooltip: 'Offline packs',
            icon: const Icon(Icons.offline_bolt_outlined),
            onPressed: _openOfflinePacks,
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Zoom without pinching: one-handed, and usable on an emulator.
          FloatingActionButton.small(
            heroTag: 'zoomIn',
            tooltip: 'Zoom in',
            backgroundColor: const Color(0xFFFFFBF0),
            foregroundColor: const Color(0xFF1B4332),
            onPressed: () => _zoom(zoomIn: true),
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 6),
          FloatingActionButton.small(
            heroTag: 'zoomOut',
            tooltip: 'Zoom out',
            backgroundColor: const Color(0xFFFFFBF0),
            foregroundColor: const Color(0xFF1B4332),
            onPressed: () => _zoom(zoomIn: false),
            child: const Icon(Icons.remove),
          ),
          const SizedBox(height: 16),
          FloatingActionButton.small(
            heroTag: 'track',
            tooltip:
                _recording ? 'Stop and save track' : 'Start track recording',
            backgroundColor:
                _recording ? Theme.of(context).colorScheme.error : null,
            foregroundColor:
                _recording ? Theme.of(context).colorScheme.onError : null,
            onPressed: _recording ? _stopTrackRecording : _startTrackRecording,
            child: Icon(_recording ? Icons.stop : Icons.route),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'locate',
            tooltip: 'Zoom to my location',
            onPressed: _locating ? null : _goToMyLocation,
            child:
                _locating
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.my_location),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_stylesReady)
            MapLibreMap(
              key: ValueKey('map-$_mapEpoch-${_basemap.name}'),
              styleString: _styleString,
              // Not a constant: on a basemap swap this rebuild is a fresh map
              // widget, and starting it where the old one stood is what keeps
              // the view from snapping back to the province.
              initialCameraPosition: _camera,
              onMapCreated: (controller) {
                _map = controller;
                controller.onFeatureTapped.add(_onFeatureTapped);
              },
              onStyleLoadedCallback: () async {
                _styleReady = true;
                // A new style has no images, whatever the last one had.
                _iconsRegistered = false;
                await _attachLayers();
                await _syncWaypointSource();
                await _syncActiveTrackSource();
                await _syncOfflineAreaSource();
                if (_identifiedLocation != null) {
                  await _setIdentifyPin(_identifiedLocation!);
                }
                // Only frame the map when the province changed. A basemap swap
                // fires this callback too, and re-framing there would undo the
                // pan the user switched basemaps to look at.
                if (_framedProvince != _provinceId) {
                  final firstRun = _framedProvince == null;
                  _framedProvince = _provinceId;
                  // The map was built on the user's own position, so framing
                  // the province here would throw that away immediately.
                  if (!firstRun || !_openedOnUser) {
                    await _flyToProvince(_provinceId);
                  }
                }
              },
              onCameraMove: (position) {
                _camera = position;
              },
              onMapClick: _identify,
              featureTapsTriggersMapClick: true,
              // Shown after the user grants location (see _goToMyLocation /
              // track recording). Compass mode draws a heading-aware arrow.
              myLocationEnabled: _myLocationEnabled,
              myLocationRenderMode: _myLocationEnabled
                  ? MyLocationRenderMode.compass
                  : MyLocationRenderMode.normal,
              myLocationTrackingMode: MyLocationTrackingMode.none,
              compassEnabled: true,
              // Off by default, and without it the native side never emits a
              // camera event: onCameraMove goes silent and controller
              // .cameraPosition stays null, so a basemap swap rebuilt the map
              // at whatever position was last set in code rather than where
              // the user had panned to.
              trackCameraPosition: true,
            ),
          if (_needsPack)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                color: const Color(0xFFFFFBF0),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'No map data for $_provinceCode yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Crown land, parks, WMUs and hunting seasons ship as a '
                        'downloadable pack so the data can be refreshed '
                        'without an app update. Download it once and it works '
                        'offline.',
                        style: TextStyle(height: 1.35),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _openOfflinePacks,
                        icon: const Icon(Icons.download),
                        label: Text('Get $_provinceCode data'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Along the top, because the bottom edge already carries the basemap
          // attribution, the zoom pair, locate and the record button, and this
          // bar stays on screen for as long as the walk does.
          if (_followTrack case final track?)
            Positioned(
              left: 8,
              right: 8,
              top: 8,
              child: FollowBar(
                track: track,
                reversed: _followReversed,
                guidance: _followGuidance,
                onReverse: _reverseFollowing,
                onStop: _stopFollowing,
              ),
            ),
          if (_highlightedArea != null)
            Positioned(
              left: 8,
              // Clear of the basemap attribution along the bottom edge, which is
              // a licence condition and not ours to cover up, and of the zoom and
              // locate buttons down the right, which otherwise sit on top of this
              // banner's dismiss button.
              right: 76,
              bottom: 30,
              child: Material(
                color: const Color(0xE61B4332),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(Icons.crop_free,
                          size: 16, color: Color(0xFF76FF03)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _offlineAreas.length > 1
                              ? 'Saved offline: ${_highlightedArea!.name}, '
                                  'outlined with your other '
                                  '${_offlineAreas.length - 1} area'
                                  '${_offlineAreas.length > 2 ? 's' : ''}'
                              : 'Saved offline: ${_highlightedArea!.name}',
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: Color(0xFFFFFBF0),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: const Color(0xFFFFFBF0),
                        tooltip: 'Hide outlines',
                        visualDensity: VisualDensity.compact,
                        onPressed: _clearOfflineAreas,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showLandInfoTip && !_needsPack)
            Positioned(
              left: 8,
              top: 8,
              right: 8,
              child: Material(
                color: const Color(0xE6FFF3CD),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Amber = Crown land, paler where no land use policy '
                            'covers it. Violet = leased or occupied Crown land, '
                            'where the holder may refuse entry. Cyan = '
                            'municipal & county forest; the gaps between tracts '
                            'are private. Blue = parks. Red = no shooting. '
                            'Colour shows tenure, not permission — tap any spot '
                            'for Land Info.',
                            style: TextStyle(fontSize: 12, height: 1.3),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Dismiss',
                        visualDensity: VisualDensity.compact,
                        onPressed: _dismissLandInfoTip,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_stylesReady && _error == null)
            const ColoredBox(
              color: Color(0x66FFFBF0),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error case final message?)
            Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: const Color(0xFFFFE0B2),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(message, textAlign: TextAlign.center),
                ),
              ),
            ),
          Positioned(
            left: 8,
            bottom: 6,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xCCFFFBF0)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text(
                  _basemap.shortHint,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickBasemap() async {
    final next = await showModalBottomSheet<BasemapKind>(
      context: context,
      showDragHandle: true,
      // Without this the sheet is capped near half the screen, which in
      // landscape is shorter than the list of basemaps. The panel constrains its
      // own height.
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: BasemapPanel(
          selected: _basemap,
          onPick: (kind) => Navigator.pop(context, kind),
        ),
      ),
    );
    if (next == null || next == _basemap) return;
    // Ask the platform where the camera actually is before dropping the
    // controller. onCameraMove keeps _camera fresh during gestures, but this is
    // the one moment where being wrong is visible, so round-trip for it.
    final current = await _map?.queryCameraPosition();
    if (!mounted) return;
    setState(() {
      if (current != null) _camera = current;
      _basemap = next;
      _styleReady = false;
      _mapEpoch++;
      _map = null;
    });
  }

  Future<void> _dismissLandInfoTip() async {
    setState(() => _showLandInfoTip = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_landInfoTipDismissedKey, true);
  }

  Future<void> _enableMyLocationPuck() async {
    if (_myLocationEnabled) return;
    setState(() => _myLocationEnabled = true);
  }

  /// One zoom level per tap. MapLibre clamps at the style's min/max, so the
  /// buttons go quiet at the ends rather than needing to be disabled.
  Future<void> _zoom({required bool zoomIn}) async {
    final map = _map;
    if (map == null) return;
    await map.animateCamera(
      zoomIn ? CameraUpdate.zoomIn() : CameraUpdate.zoomOut(),
    );
  }

  /// Where to open the map, or null to fall back to the province.
  ///
  /// Silent whatever happens: the user did not ask for this, so a refused
  /// permission, location switched off, or a fix that never arrives should
  /// leave them looking at the province instead of at a toast every launch. The
  /// location button is still there and still explains itself when tapped.
  Future<LatLng?> _resolveLaunchLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      try {
        // Medium accuracy on purpose. Framing a map needs a rough position,
        // not a survey point, and asking for less is what keeps a cold start
        // from sitting on the loading screen.
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 6),
          ),
        );
        return LatLng(position.latitude, position.longitude);
      } catch (_) {
        // No fresh fix in time. A cached one still beats the province centre,
        // and the puck will correct itself as soon as the real fix lands.
        final last = await Geolocator.getLastKnownPosition();
        return last == null ? null : LatLng(last.latitude, last.longitude);
      }
    } catch (_) {
      return null;
    }
  }

  /// Animates the camera and records where it is going, so a basemap swap mid
  /// animation still rebuilds at the right place.
  Future<void> _moveCamera(
    MapLibreMapController map,
    LatLng target,
    double zoom,
  ) async {
    _camera = CameraPosition(target: target, zoom: zoom);
    await map.animateCamera(CameraUpdate.newCameraPosition(_camera));
  }

  Future<void> _goToMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await _ensureLocationPermission('zoom to your position')) return;
      await _enableMyLocationPuck();
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final map = _map;
      if (map == null) {
        _toast('Map is still loading — try again in a moment.');
        return;
      }
      await _moveCamera(
        map,
        LatLng(position.latitude, position.longitude),
        _myLocationZoom,
      );
    } catch (error) {
      _toast('Could not get location: $error');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<bool> _ensureLocationPermission(String purpose) async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _toast('Turn on location services to $purpose.');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _toast('Location permission is required to $purpose.');
      return false;
    }
    return true;
  }

  Future<void> _startTrackRecording() async {
    if (!await _ensureLocationPermission('record a track')) return;
    await _enableMyLocationPuck();
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _rejectedFixes = 0;
      _activeTrack
        ..clear()
        ..add(_trackPointFrom(position));
      if (mounted) setState(() => _recording = true);
      await _syncActiveTrackSource();
      _startPositionStream();
    } catch (error) {
      _toast('Could not start track recording: $error');
    }
  }

  /// One position stream for both recording and following.
  ///
  /// They can run at once — recording the way in while following a route back out
  /// is an ordinary thing to want — and two subscriptions at high accuracy would
  /// double the GPS work for the same fixes.
  void _startPositionStream() {
    if (_positionSubscription != null) return;
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        // Standing still otherwise piles up fixes at one spot, which inflates a
        // recorded track's point count and its length with pure noise.
        distanceFilter: 5,
      ),
    ).listen(
      _onPosition,
      onError: (Object error) => _toast('Location error: $error'),
    );
  }

  /// Drops the stream once neither recording nor following wants it.
  Future<void> _stopPositionStreamIfIdle() async {
    if (_recording || _followTrack != null) return;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  void _onPosition(Position position) {
    _lastPosition = position;
    if (_recording) _recordPosition(position);
    if (_followTrack != null) _updateFollow(position);
  }

  /// The worst horizontal accuracy a fix may report and still be recorded.
  ///
  /// Consumer GPS manages 3-5 m under open sky and 10-20 m under canopy, so 50 m
  /// rejects the wild fixes that put a spike in the line and add hundreds of
  /// phantom metres to the track's length, while keeping everything a phone
  /// plausibly knows. It is deliberately generous: dropping a real fix loses
  /// part of the walk, and the count of what was dropped is reported on save so
  /// a track recorded in a bad spot does not quietly look like a good one.
  static const _worstUsableAccuracyMetres = 50.0;

  /// Carries across whatever the platform reported and nothing it did not.
  ///
  /// `altitude` on Android is height above the WGS84 ellipsoid, which is not the
  /// mean-sea-level elevation many GPX readers assume — the two differ by around
  /// 35 m in southern Ontario. We write the reading through unchanged rather
  /// than correcting it, because correcting it needs a geoid model we do not
  /// ship; this is one of the reasons no total ascent is derived from it.
  TrackPoint _trackPointFrom(Position position) => TrackPoint(
    latitude: position.latitude,
    longitude: position.longitude,
    elevation: position.altitude,
    time: position.timestamp,
  );

  void _recordPosition(Position position) {
    if (!_recording) return;
    // A fix the device itself says it is unsure of. Counted rather than
    // silently ignored: "saved 412 points, dropped 6 poor fixes" is the
    // difference between a gap you know about and one you do not.
    if (position.accuracy > _worstUsableAccuracyMetres) {
      _rejectedFixes++;
      return;
    }
    final point = _trackPointFrom(position);
    final last = _activeTrack.last;
    if (last.latitude == point.latitude && last.longitude == point.longitude) {
      return;
    }
    _activeTrack.add(point);
    if (mounted) setState(() {});
    _syncActiveTrackSource();
  }

  Future<void> _stopTrackRecording() async {
    _recording = false;
    await _stopPositionStreamIfIdle();
    final points = List<TrackPoint>.from(_activeTrack);
    final rejected = _rejectedFixes;
    _activeTrack.clear();
    _rejectedFixes = 0;
    if (mounted) setState(() => _recording = false);
    await _syncActiveTrackSource();
    // One point is not a line, and saving it would leave a track in the list
    // that draws nothing on the map. Naming the dropped fixes matters most
    // here: under heavy canopy this is what "I walked for an hour and got
    // nothing" actually looks like, and the user deserves the reason.
    if (points.length < 2) {
      _toast(
        rejected > 0
            ? 'Not enough usable positions to make a track. '
                  '$rejected fix(es) were too imprecise to use.'
            : 'Not enough positions were recorded to make a track.',
      );
      return;
    }
    final stoppedAt = DateTime.now();
    await _waypoints.add(
      Waypoint(
        id: stoppedAt.microsecondsSinceEpoch.toString(),
        name: 'Track ${_formatTrackName(stoppedAt)}',
        latitude: points.first.latitude,
        longitude: points.first.longitude,
        notes: '',
        createdAt: stoppedAt,
        track: points,
      ),
    );
    await _syncWaypointSource();
    final summary = StringBuffer(
      'Saved ${formatDistance(trackLengthMetres(points))}',
    );
    if (trackDuration(points) case final duration?) {
      summary.write(' in ${formatDuration(duration)}');
    }
    if (rejected > 0) summary.write(' · dropped $rejected poor fix(es)');
    _toast(summary.toString());
  }

  Future<void> _startFollowing(
    Waypoint track, {
    required bool reversed,
  }) async {
    if (track.track.length < 2) {
      _toast('"${track.name}" has no line to follow.');
      return;
    }
    if (!await _ensureLocationPermission('follow a track')) return;
    await _enableMyLocationPuck();
    if (!mounted) return;
    setState(() {
      _followTrack = track;
      _followReversed = reversed;
      _followPoints = orientTrack(track.track, reversed: reversed);
      _followCumulative = cumulativeMetres(_followPoints);
      _followGuidance = null;
      _arrivalAnnounced = false;
    });
    // The whole track first, so the user can see what they have committed to
    // before the camera is anywhere near them.
    await _revealWaypoint(track);
    await _syncFollowSource();
    // Drawn without the followed track, so its arrows come only from the follow
    // layer and point the way being walked rather than the way it was recorded.
    await _syncSavedTrackSource();
    _startPositionStream();
    // Seeded from a fix of our own rather than waiting for the stream, which with
    // a 5 m filter may not emit for as long as the user stands still reading it.
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _lastPosition = position;
      _updateFollow(position);
    } catch (_) {
      // The bar says it is waiting for a fix, which is true and is all we know.
    }
  }

  Future<void> _stopFollowing() async {
    setState(() {
      _followTrack = null;
      _followPoints = const [];
      _followCumulative = const [];
      _followGuidance = null;
    });
    await _stopPositionStreamIfIdle();
    await _syncFollowSource();
    await _syncSavedTrackSource();
  }

  /// Turns around without leaving the track.
  Future<void> _reverseFollowing() async {
    final track = _followTrack;
    if (track == null) return;
    setState(() {
      _followReversed = !_followReversed;
      _followPoints = orientTrack(track.track, reversed: _followReversed);
      _followCumulative = cumulativeMetres(_followPoints);
      _arrivalAnnounced = false;
    });
    // Re-drawn because the arrows have to turn round with the decision.
    await _syncFollowSource();
    final position = _lastPosition;
    if (position != null) _updateFollow(position);
  }

  void _updateFollow(Position position) {
    if (_followTrack == null) return;
    final guidance = guidanceAlong(
      _followPoints,
      position.latitude,
      position.longitude,
      cumulative: _followCumulative,
    );
    if (mounted) setState(() => _followGuidance = guidance);
    _syncFollowPositionSource();
    if (guidance != null && guidance.arrived && !_arrivalAnnounced) {
      _arrivalAnnounced = true;
      _toast('End of "${_followTrack!.name}".');
    }
  }

  String _formatTrackName(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _attachLayers() async {
    final map = _map;
    final data = _provinceData;
    if (!_styleReady || map == null || data == null) return;
    try {
      await _overlays.attach(map, data.layers);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not draw overlays: $error');
    }
  }

  Future<void> _syncWaypointSource() async {
    final map = _map;
    if (!_styleReady || map == null) return;
    final featureCollection = {
      'type': 'FeatureCollection',
      'features': [
        for (final waypoint in _waypoints.items.where(
          (item) => item.track.isEmpty,
        ))
          {
            'type': 'Feature',
            'properties': {
              'name': waypoint.name,
              'id': waypoint.id,
              'icon': waypoint.category.iconImage,
              'colour': waypoint.colourHex,
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [waypoint.longitude, waypoint.latitude],
            },
          },
      ],
    };
    await _ensureWaypointIcons();
    for (final layer in const [
      'owm-waypoint-symbols',
      'owm-waypoint-dots',
    ]) {
      try {
        await map.removeLayer(layer);
      } catch (_) {}
    }
    try {
      await map.removeSource('owm-waypoints');
    } catch (_) {}
    await map.addSource(
      'owm-waypoints',
      GeojsonSourceProperties(data: featureCollection),
    );
    // A small dot under every glyph, marking the exact coordinate the centred
    // glyph only approximates.
    //
    // It is also the fallback, and that is not hypothetical: a software GL stack
    // draws fills, lines and circles but no symbol layers at all, so on one the
    // glyphs vanish and the basemap loses its own labels too. Android emulators
    // are a supported target here, BlueStacks included. Without this a waypoint
    // on such a device would render as nothing whatsoever, which is the kind of
    // silent wrong answer this app is not allowed to give.
    await map.addCircleLayer(
      'owm-waypoints',
      'owm-waypoint-dots',
      const CircleLayerProperties(
        circleRadius: 3,
        circleColor: ['get', 'colour'],
        circleStrokeWidth: 1.5,
        circleStrokeColor: '#FFFFFF',
      ),
    );
    try {
      await _addWaypointSymbolLayer(map);
    } catch (error) {
      // The dots above are already drawn, so a throw here leaves the waypoints
      // visible but unglyphed rather than invisible. Said out loud because the
      // difference is not something the user could otherwise work out.
      _toast('Waypoint icons could not be drawn: $error');
    }
    await _syncSavedTrackSource();
  }

  Future<void> _addWaypointSymbolLayer(MapLibreMapController map) =>
      map.addSymbolLayer(
        'owm-waypoints',
        'owm-waypoint-symbols',
        SymbolLayerProperties(
          iconImage: const ['get', 'icon'],
          iconColor: const ['get', 'colour'],
          iconSize: _waypointIconSize,
          // Waypoints cluster where the hunting is good, and a symbol layer
          // drops colliding icons by default. Losing the one you are looking
          // for because it sits near another is worse than a little overlap.
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
          // Only SDF images can take a halo, and the halo is what keeps a dark
          // glyph readable on a satellite basemap and a light one on snow.
          iconHaloColor: '#FFFFFF',
          iconHaloWidth: 1.0,
          iconHaloBlur: 0.2,
        ),
      );

  /// `icon-size` that draws a 64 px source image at [logicalPixels] on screen.
  ///
  /// MapLibre draws an added image at its own pixel size and Android decodes it
  /// unscaled, so a fixed icon-size would make a glyph 64 physical pixels
  /// everywhere: cramped on a dense phone, oversized on a cheap tablet. iOS
  /// builds the image with its own scale factor and may not need the same
  /// correction, which is untested here because this project has no Mac.
  double _iconSizeFor(double logicalPixels) =>
      logicalPixels * MediaQuery.devicePixelRatioOf(context) / 64;

  /// Waypoint glyphs are meant to read at 24 dp.
  double get _waypointIconSize => _iconSizeFor(24);

  /// Puts the waypoint glyphs into the current style, once per style.
  ///
  /// Images belong to a style rather than to the map, so every style load — and
  /// that includes every basemap swap — drops them. They have to go back before
  /// any layer names one, because a symbol layer whose icon-image is missing
  /// draws nothing at all and reports nothing about why.
  ///
  /// Called from the sync rather than only from the style-load callback so that
  /// every path which creates the layer also guarantees its images. Failures are
  /// caught and surfaced instead of propagating: this used to run directly in
  /// `onStyleLoadedCallback`, where one throw from `addImage` abandoned the rest
  /// of the callback and took the overlays and the identify pin down with it.
  Future<void> _ensureWaypointIcons() async {
    final map = _map;
    if (map == null || _iconsRegistered) return;
    final wanted = {
      for (final category in WaypointCategory.values)
        category.iconImage: 'assets/waypoint_icons/${category.id}.png',
      trackArrowImage: trackArrowAsset,
    };
    final failures = <String>[];
    for (final entry in wanted.entries) {
      try {
        var bytes = _iconBytes[entry.key];
        if (bytes == null) {
          final data = await rootBundle.load(entry.value);
          bytes = data.buffer.asUint8List();
          _iconBytes[entry.key] = bytes;
        }
        // The third argument is what marks these as signed distance fields, and
        // it is what makes icon-color apply. Without it every waypoint draws in
        // the glyph's own white and the colours do nothing.
        await map.addImage(entry.key, bytes, true);
      } catch (error) {
        failures.add('${entry.key}: $error');
      }
    }
    if (failures.isEmpty) {
      _iconsRegistered = true;
      return;
    }
    // Said out loud rather than swallowed. Without the glyphs the waypoints are
    // still in the list but invisible on the map, and a saved waypoint that is
    // silently not drawn is the kind of quiet wrong answer this app must not
    // give: the dot under each glyph is there so something still shows.
    _toast('Some waypoint icons could not be drawn (${failures.first}).');
  }

  Future<void> _syncSavedTrackSource() async {
    final map = _map;
    if (!_styleReady || map == null) return;
    // The followed track is drawn by the follow layers instead, so its arrows
    // come from the direction being walked rather than the direction it was
    // recorded in. Leaving it here too would put two sets of arrows on one line,
    // pointing opposite ways whenever it is being followed in reverse.
    final followedId = _followTrack?.id;
    final data = _trackFeatureCollection(
      _waypoints.items.where(
        (item) => item.track.isNotEmpty && item.id != followedId,
      ),
    );
    // Arrows come off before the line, because a layer cannot be removed once
    // its source has gone and leaving it behind blocks the source from being
    // replaced.
    for (final layer in const [
      'owm-saved-track-arrows',
      'owm-saved-track-lines',
    ]) {
      try {
        await map.removeLayer(layer);
      } catch (_) {}
    }
    try {
      await map.removeSource('owm-saved-tracks');
    } catch (_) {}
    await map.addSource(
      'owm-saved-tracks',
      GeojsonSourceProperties(data: data),
    );
    await map.addLineLayer(
      'owm-saved-tracks',
      'owm-saved-track-lines',
      const LineLayerProperties(
        lineColor: ['get', 'colour'],
        lineWidth: trackLineWidth,
        lineOpacity: 0.85,
        // Round, so a track that doubles back on itself does not grow spikes at
        // the switchbacks where two segments meet at a sharp angle.
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    try {
      await _addTrackArrowLayer(map);
    } catch (error) {
      // The line still carries the track; only its direction is lost. Worth
      // saying so, because the same failure on a software GL stack takes the
      // waypoint glyphs with it and the two are one diagnosis.
      _toast('Track direction arrows could not be drawn: $error');
    }
  }

  /// Repeated arrows along each track, showing which way it runs.
  Future<void> _addTrackArrowLayer(
    MapLibreMapController map, {
    String source = 'owm-saved-tracks',
    String layer = 'owm-saved-track-arrows',
  }) async {
    if (!_trackArrows.value) return;
    return map.addSymbolLayer(
        source,
        layer,
        SymbolLayerProperties(
          iconImage: trackArrowImage,
          // Placed along the line, which is also what orients each arrow: the
          // symbol's horizontal axis is aligned with the direction the
          // coordinates run, and ours run start to finish.
          symbolPlacement: 'line',
          symbolSpacing: trackArrowSpacing,
          // Rotate with the map rather than the screen. Without this the arrows
          // stay upright as the map turns and stop agreeing with the line.
          iconRotationAlignment: 'map',
          // Load-bearing despite matching the default. When true, MapLibre flips
          // a symbol to keep it reading left-to-right, which silently reverses
          // every arrow on a westward leg — the one failure mode that would make
          // this feature actively lie about which way the track goes.
          iconKeepUpright: false,
          iconColor: const ['get', 'arrow'],
          // Halo in the track's own colour, so each arrow reads as a hole
          // punched in the line rather than a separate mark beside it.
          iconHaloColor: const ['get', 'colour'],
          iconHaloWidth: 1.2,
          iconSize: _iconSizeFor(trackArrowSizeDp),
          // Kept rather than thinned. Collision culling makes arrows come and go
          // as the camera moves, which reads as a rendering fault on a feature
          // whose only job is to be legible.
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
      );
  }

  /// The followed track, drawn heavier and pointing the way being walked.
  Future<void> _syncFollowSource() async {
    final map = _map;
    if (!_styleReady || map == null) return;
    for (final layer in const ['owm-follow-arrows', 'owm-follow-line']) {
      try {
        await map.removeLayer(layer);
      } catch (_) {}
    }
    try {
      await map.removeSource('owm-follow');
    } catch (_) {}
    final track = _followTrack;
    if (track == null || _followPoints.length < 2) return;

    await map.addSource(
      'owm-follow',
      GeojsonSourceProperties(
        data: {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'properties': {
                'id': track.id,
                'colour': track.colourHex,
                'arrow': arrowColourFor(track.displayColour),
              },
              'geometry': {
                'type': 'LineString',
                // Already oriented, which is what turns the arrows round.
                'coordinates': [
                  for (final point in _followPoints)
                    [point.longitude, point.latitude],
                ],
              },
            },
          ],
        },
      ),
    );
    await map.addLineLayer(
      'owm-follow',
      'owm-follow-line',
      const LineLayerProperties(
        lineColor: ['get', 'colour'],
        // Heavier than an unfollowed track, so which one is being followed is
        // visible without reading the bar.
        lineWidth: trackLineWidth + 3,
        lineOpacity: 0.95,
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    try {
      await _addTrackArrowLayer(map, source: 'owm-follow', layer: 'owm-follow-arrows');
    } catch (error) {
      _toast('Track direction arrows could not be drawn: $error');
    }
  }

  /// A dot on the line at the point the guidance is measured from.
  ///
  /// Worth drawing rather than trusting: every number in the bar is relative to
  /// this spot, and if the app has put it somewhere absurd the user can see that
  /// for themselves instead of being given a confident distance to nowhere. A
  /// circle rather than a symbol so it still draws on a software GL stack, which
  /// renders no symbol layers at all.
  Future<void> _syncFollowPositionSource() async {
    final map = _map;
    if (!_styleReady || map == null) return;
    final guidance = _followGuidance;
    final data = {
      'type': 'FeatureCollection',
      'features': [
        if (guidance != null)
          {
            'type': 'Feature',
            'properties': {
              'colour': arrowColourFor(
                _followTrack?.displayColour ?? const Color(0xFF000000),
              ),
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [guidance.longitude, guidance.latitude],
            },
          },
      ],
    };
    try {
      await map.setGeoJsonSource('owm-follow-position', data);
      return;
    } catch (_) {}
    try {
      await map.addSource(
        'owm-follow-position',
        GeojsonSourceProperties(data: data),
      );
      await map.addCircleLayer(
        'owm-follow-position',
        'owm-follow-position-dot',
        const CircleLayerProperties(
          circleRadius: 5,
          circleColor: ['get', 'colour'],
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
      );
    } catch (_) {
      // The bar still has every number in it; only the dot is missing.
    }
  }

  Future<void> _syncActiveTrackSource() async {
    final map = _map;
    if (!_styleReady || map == null) return;
    final data = {
      'type': 'FeatureCollection',
      'features': [
        if (_activeTrack.length >= 2)
          {
            'type': 'Feature',
            'properties': const {'kind': 'active-track'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final point in _activeTrack)
                  [point.longitude, point.latitude],
              ],
            },
          },
      ],
    };
    try {
      await map.setGeoJsonSource('owm-active-track', data);
      return;
    } catch (_) {}
    try {
      await map.addSource(
        'owm-active-track',
        GeojsonSourceProperties(data: data),
      );
      await map.addLineLayer(
        'owm-active-track',
        'owm-active-track-line',
        const LineLayerProperties(
          lineColor: '#D32F2F',
          lineWidth: 5,
          lineOpacity: 0.95,
        ),
      );
    } catch (_) {
      // A style change can race a position update; the next update resyncs it.
    }
  }

  Map<String, dynamic> _trackFeatureCollection(Iterable<Waypoint> tracks) => {
    'type': 'FeatureCollection',
    'features': [
      for (final waypoint in tracks)
        if (waypoint.track.length >= 2)
          {
            'type': 'Feature',
            'properties': {
              'name': waypoint.name,
              'id': waypoint.id,
              // Per feature, so one layer draws every track in its own colour
              // rather than one layer per track.
              'colour': waypoint.colourHex,
              // Resolved here rather than in the style, because MapLibre has no
              // expression for "a colour that contrasts with this one".
              'arrow': arrowColourFor(waypoint.displayColour),
            },
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final point in waypoint.track)
                  [point.longitude, point.latitude],
              ],
            },
          },
    ],
  };

  Future<void> _selectProvince(String id) async {
    setState(() {
      _provinceId = id;
      _provinceData = null;
      _error = null;
      _identifiedLocation = null;
    });
    await _loadProvinceData(id);
    if (!mounted || id != _provinceId) return;
    await _clearIdentifyPin();
    await _flyToProvince(id);
    if (!mounted) return;
    final province = _selectedProvince;
    if (province != null && province.isPreview) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text('${province.name} data is a preview.'),
          action: SnackBarAction(
            label: 'DETAILS',
            onPressed: _showProvinceStatus,
          ),
        ),
      );
    }
  }

  Future<void> _flyToProvince(String id) async {
    final map = _map;
    if (map == null) return;
    final target =
        id == 'qc' ? const LatLng(45.5, -75.7) : const LatLng(45.1, -75.75);
    await _moveCamera(map, target, _sampleZoom);
  }

  void _onFeatureTapped(
    math.Point<double> point,
    LatLng coordinates,
    String id,
    String? layerId,
    Annotation? annotation,
  ) {
    // Backup path when a fill/line absorbs the tap (even with
    // featureTapsTriggersMapClick). Ignore our own pin/waypoints.
    if (layerId == 'owm-identify-circle' ||
        layerId == 'owm-waypoint-symbols' ||
        layerId == 'owm-waypoint-dots') {
      return;
    }
    _identify(point, coordinates);
  }

  Future<void> _clearIdentifyPin() async {
    _identifiedLocation = null;
    final map = _map;
    if (map == null) return;
    try {
      await map.removeLayer('owm-identify-circle');
    } catch (_) {}
    try {
      await map.removeSource('owm-identify');
    } catch (_) {}
  }

  Future<void> _setIdentifyPin(LatLng coordinates) async {
    _identifiedLocation = coordinates;
    final map = _map;
    if (map == null || !_styleReady) return;
    final featureCollection = {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': const {'kind': 'identify'},
          'geometry': {
            'type': 'Point',
            'coordinates': [coordinates.longitude, coordinates.latitude],
          },
        },
      ],
    };
    try {
      await map.removeLayer('owm-identify-circle');
    } catch (_) {}
    try {
      await map.removeSource('owm-identify');
    } catch (_) {}
    await map.addSource(
      'owm-identify',
      GeojsonSourceProperties(data: featureCollection),
    );
    await map.addCircleLayer(
      'owm-identify',
      'owm-identify-circle',
      const CircleLayerProperties(
        circleRadius: 8,
        circleColor: '#B3261E',
        circleStrokeWidth: 3,
        circleStrokeColor: '#FFFFFF',
      ),
    );
  }

  Future<void> _identify(math.Point<double> point, LatLng coordinates) async {
    final data = _provinceData;
    final map = _map;
    if (data == null || map == null) return;
    // One tap on a fill arrives twice: once as a map click and once through the
    // feature-tap backup path above. Both then race to replace the pin layer,
    // and the loser throws "layer already exists". Keyed on the point rather
    // than timed, so two quick taps in different places both still resolve.
    if (_identifying == point) return;
    _identifying = point;
    try {
      final hits = await _hitsAt(map, point);
      await _setIdentifyPin(coordinates);
      if (!mounted) return;
      await showLandInfoSheet(
        context,
        info: LandInfo(
          latitude: coordinates.latitude,
          longitude: coordinates.longitude,
          hits: hits,
          attribution: '${data.manifest.license}. ${data.manifest.licenseUrl}',
        ),
        provinceId: _provinceId,
        loader: _loader,
        manifest: data.manifest,
        seasons: data.seasons,
        layers: data.layers,
      );
    } finally {
      _identifying = null;
    }
  }

  /// Resolves what sits under [point] by asking MapLibre, which already holds
  /// the parcel geometry it parsed from the pack.
  ///
  /// Queried one layer at a time because the answer is a bare list of features
  /// — the layer each hit came from is only knowable from what we asked for.
  Future<List<LandFeature>> _hitsAt(
    MapLibreMapController map,
    math.Point<double> point,
  ) async {
    final hits = <LandFeature>[];
    for (final layerId in _overlays.identifiableLayerIds) {
      final List<dynamic> found;
      try {
        found = await map.queryRenderedFeatures(
          point,
          [_overlays.fillLayerId(layerId)],
          null,
        );
      } catch (_) {
        // A tap can race a style reload; the pin still drops and the next
        // tap resolves normally.
        continue;
      }
      // One parcel spanning several tiles comes back once per tile.
      final seen = <String>{};
      final defaults = _overlays.layers[layerId]?.featureDefaults ?? const {};
      for (final feature in found) {
        if (feature is! Map<String, dynamic>) continue;
        final properties = feature['properties'];
        if (!seen.add(jsonEncode(properties))) continue;
        hits.add(LandFeature.fromGeoJson(layerId, feature, defaults: defaults));
      }
    }
    return hits;
  }

  /// Takes a pasted coordinate, moves the map there and marks the spot.
  ///
  /// It marks rather than opening Land Info outright. The card is assembled from
  /// the features MapLibre has actually rendered under a screen point, and
  /// querying that in the instant after an animated camera move can come back
  /// empty simply because the tiles have not arrived. Empty reads on the card as
  /// "we have no record here", which is a different and far worse answer than
  /// "not drawn yet". The snackbar action runs the same identify a moment later,
  /// once it can tell the truth.
  Future<void> _searchCoordinate() async {
    final found = await showCoordinateSearch(context);
    if (!mounted || found == null) return;
    final map = _map;
    if (map == null) return;
    final target = LatLng(found.latitude, found.longitude);
    await _moveCamera(map, target, _waypointRevealZoom);
    await _setIdentifyPin(target);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${found.latitude.toStringAsFixed(6)}, '
          '${found.longitude.toStringAsFixed(6)}',
        ),
        action: SnackBarAction(
          label: 'Land info',
          onPressed: () => _identifyAt(target),
        ),
      ),
    );
  }

  /// Runs the tap-to-identify path at a coordinate rather than a screen tap.
  Future<void> _identifyAt(LatLng target) async {
    final map = _map;
    if (map == null) return;
    final point = await map.toScreenLocation(target);
    if (!mounted) return;
    await _identify(
      math.Point<double>(point.x.toDouble(), point.y.toDouble()),
      target,
    );
  }

  void _showLayers() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Without this the sheet is capped near half the screen, which is shorter
      // than the layer list. The panel constrains its own height.
      isScrollControlled: true,
      builder: (_) =>
          LayerPanel(controller: _overlays, trackArrows: _trackArrows),
    );
  }

  Future<void> _showWaypoints() async {
    final request = await Navigator.push<WaypointsRequest>(
      context,
      MaterialPageRoute(
        builder:
            (_) => WaypointsPage(
              store: _waypoints,
              suggestedLocation: _identifiedLocation ?? _camera.target,
            ),
      ),
    );
    if (!mounted) return;
    final reveal = switch (request) {
      RevealWaypoint(:final waypoint) => waypoint,
      // Following frames the track itself, so there is nothing left to reveal.
      FollowTrack() => null,
      null => null,
    };
    await _syncWaypointSource();
    // Deleting a track from the list used to leave its line on the map until
    // the next style load, because only the point source was re-read here.
    await _syncSavedTrackSource();
    if (reveal != null) await _revealWaypoint(reveal);
    if (request case FollowTrack(:final track, :final reversed)) {
      await _startFollowing(track, reversed: reversed);
    }
  }

  /// Puts a saved waypoint or track on screen after the list hands one back.
  ///
  /// A track gets its whole extent framed rather than its first point centred.
  /// Its stored latitude and longitude are the start of the walk, so centring
  /// on them at a fixed zoom is as likely to show an empty corner of the route
  /// as the route.
  Future<void> _revealWaypoint(Waypoint waypoint) async {
    final map = _map;
    if (map == null) return;
    if (waypoint.track.length < 2) {
      await _moveCamera(
        map,
        LatLng(waypoint.latitude, waypoint.longitude),
        _waypointRevealZoom,
      );
      return;
    }
    var south = waypoint.track.first.latitude;
    var north = south;
    var west = waypoint.track.first.longitude;
    var east = west;
    for (final point in waypoint.track) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    await map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(south, west),
          northeast: LatLng(north, east),
        ),
        left: 48,
        right: 48,
        top: 48,
        bottom: 48,
      ),
    );
  }
}
