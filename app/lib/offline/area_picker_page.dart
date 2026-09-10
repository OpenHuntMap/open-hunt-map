import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../map/basemap.dart';
import 'basemap_area_store.dart';
import 'basemap_sources.dart';
import 'tile_math.dart';

/// What the picker hands back for the offline page to download.
class AreaDownloadRequest {
  const AreaDownloadRequest({
    required this.name,
    required this.basemap,
    required this.bounds,
    required this.maxZoom,
    required this.estimatedBytes,
  });

  final String name;
  final BasemapKind basemap;
  final LatLngBounds bounds;
  final int maxZoom;
  final int estimatedBytes;
}

/// The detail levels offered, and what each is for.
///
/// Zoom is meaningless to most people, so the choice is framed by what the map
/// is good for at that level rather than by the number.
enum AreaDetail {
  overview(12, 'Overview', 'Lakes, highways and towns'),
  standard(14, 'Standard', 'Side roads and bush roads'),
  detailed(16, 'Detailed', 'Individual trees and trails');

  const AreaDetail(this.zoom, this.label, this.blurb);

  final int zoom;
  final String label;
  final String blurb;

  /// The level to preselect for an area already saved to [maxZoom].
  ///
  /// A saved ceiling is not always one of these numbers: [detailCeilingFor]
  /// caps it on the way in when a basemap's sources stop short. Rounding down
  /// keeps the control from claiming detail the area does not hold.
  static AreaDetail forMaxZoom(int maxZoom) {
    var best = AreaDetail.overview;
    for (final detail in AreaDetail.values) {
      if (detail.zoom <= maxZoom) best = detail;
    }
    return best;
  }
}

/// The saved areas that discount a download, for [estimateRegionSize].
///
/// The area being edited counts among them: [BasemapAreaStore.replace]
/// downloads the new definition before dropping the old region, so the tiles it
/// holds are still on the device and are reused rather than fetched again.
/// Leaving it out would put the estimate at odds with the download it describes,
/// and would quote the full cost of an area for a change that fetches nothing.
List<ExistingCoverage> coverageForEstimate(List<BasemapArea> saved) => [
      for (final area in saved)
        // An interrupted area holds some unknown fraction of its tiles, so
        // counting it as coverage would report "already saved" and leave the
        // user no way to finish it. Ignoring it costs an overestimate; the
        // tiles that did arrive are still reused rather than fetched again.
        if (area.complete) area.coverage,
    ];

LatLng _centreOf(LatLngBounds bounds) => LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );

/// Where a download stops being something you start without thinking. Roughly
/// a typical phone viewport of imagery at the Detailed level, which is more
/// than most people expect a map to cost.
const int _largeDownloadBytes = 500 * 1024 * 1024;

/// Frame insets, in logical pixels, measured from the map's own box.
const double _frameInsetX = 20;
const double _frameInsetTop = 20;
const double _frameInsetBottom = 20;

class AreaPickerPage extends StatefulWidget {
  const AreaPickerPage({
    super.key,
    required this.initialCamera,
    required this.basemap,
    required this.existing,
    this.editing,
  });

  final CameraPosition initialCamera;
  final BasemapKind basemap;
  final List<BasemapArea> existing;

  /// The area being changed, or null when saving a new one.
  ///
  /// Its extent, basemap and detail level seed the picker, so the user starts
  /// from what they saved rather than from wherever the map was left.
  final BasemapArea? editing;

  @override
  State<AreaPickerPage> createState() => _AreaPickerPageState();
}

class _AreaPickerPageState extends State<AreaPickerPage> {
  MapLibreMapController? _map;
  late BasemapKind _basemap = _seedBasemap();
  late AreaDetail _detail = switch (widget.editing) {
    final area? => AreaDetail.forMaxZoom(area.maxZoom),
    null => AreaDetail.standard,
  };
  final Map<BasemapKind, String> _styles = {};
  final Map<BasemapKind, List<TileSourceSpec>> _sources = {};

  LatLngBounds? _frameBounds;
  SizeEstimate? _estimate;
  Size _mapSize = Size.zero;
  var _loading = true;
  var _framedEdit = false;

  @override
  void initState() {
    super.initState();
    _loadStyles();
  }

  BasemapKind _seedBasemap() {
    final kind = widget.editing?.basemap ?? widget.basemap;
    return kind.supportsOfflineAreas ? kind : BasemapKind.satellite;
  }

  /// Where the map opens before it is big enough to be framed precisely.
  CameraPosition get _initialCamera {
    final area = widget.editing;
    if (area == null) return widget.initialCamera;
    return CameraPosition(
      target: _centreOf(area.bounds),
      zoom: widget.initialCamera.zoom,
    );
  }

  Future<void> _loadStyles() async {
    for (final kind in BasemapKind.values) {
      if (!kind.supportsOfflineAreas) continue;
      final asset = kind.assetStylePath;
      if (asset == null) {
        _sources[kind] = remoteSourceSpecs(kind);
      } else {
        final style = await rootBundle.loadString(asset);
        _styles[kind] = style;
        _sources[kind] = sourceSpecsFromStyle(style);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _styleString =>
      _basemap.remoteStyleUrl ?? _styles[_basemap] ?? '{}';

  List<TileSourceSpec> get _currentSources => _sources[_basemap] ?? const [];

  int get _effectiveMaxZoom =>
      math.min(_detail.zoom, detailCeilingFor(_currentSources));

  /// Puts the rectangle being edited back inside the selection frame.
  ///
  /// The frame is pinned to the map's box, so the camera has to move to it
  /// rather than the other way round: fitting the bounds inside padding equal
  /// to the frame insets lays the two on top of each other. They coincide
  /// exactly only where the frame has the same shape as the rectangle, which it
  /// does on the screen and orientation the area was drawn on and not
  /// necessarily elsewhere; on any other the frame is the larger of the two.
  /// Nothing downstream assumes they match, because [_recomputeBounds] reads
  /// the frame back off the map afterwards.
  ///
  /// Once the saved extent is on screen this reframes on whatever is in the
  /// frame instead, so switching basemap, which rebuilds the map from its
  /// initial camera, does not throw away a rectangle the user has adjusted.
  Future<void> _frameEditedArea() async {
    final map = _map;
    final area = widget.editing;
    if (map == null || area == null) return;
    final bounds = _framedEdit ? (_frameBounds ?? area.bounds) : area.bounds;
    try {
      // This padding is in logical pixels, unlike the physical ones toLatLng
      // takes, so the frame insets go in unscaled.
      await map.moveCamera(
        CameraUpdate.newLatLngBounds(
          bounds,
          left: _frameInsetX,
          top: _frameInsetTop,
          right: _frameInsetX,
          bottom: _frameInsetBottom,
        ),
      );
      _framedEdit = true;
    } on Object {
      // A camera the map will not accept leaves the user where they are, with
      // the estimate still describing the frame that is actually drawn.
    }
  }

  /// Reads the frame's corners back through the map so the estimate covers
  /// exactly the rectangle drawn on screen.
  Future<void> _recomputeBounds() async {
    final map = _map;
    if (map == null || _mapSize == Size.zero) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // toLatLng takes physical pixels; the frame is laid out in logical ones.
    math.Point<num> at(double x, double y) => math.Point(x * ratio, y * ratio);

    try {
      final topLeft = await map.toLatLng(
        at(_frameInsetX, _frameInsetTop),
      );
      final bottomRight = await map.toLatLng(
        at(
          _mapSize.width - _frameInsetX,
          _mapSize.height - _frameInsetBottom,
        ),
      );
      if (!mounted) return;
      final bounds = LatLngBounds(
        southwest: LatLng(
          math.min(topLeft.latitude, bottomRight.latitude),
          math.min(topLeft.longitude, bottomRight.longitude),
        ),
        northeast: LatLng(
          math.max(topLeft.latitude, bottomRight.latitude),
          math.max(topLeft.longitude, bottomRight.longitude),
        ),
      );
      setState(() {
        _frameBounds = bounds;
        _estimate = _estimateFor(bounds);
      });
    } on Object {
      // A corner off the globe, or the map torn down mid-gesture. The previous
      // estimate stays on screen rather than flickering to nothing.
    }
  }

  SizeEstimate _estimateFor(LatLngBounds bounds) {
    final sources = _currentSources;
    return estimateRegionSize(
      bounds: bounds,
      minZoom: minOfflineZoom,
      maxZoom: _effectiveMaxZoom,
      sources: sources,
      existing: coverageForEstimate(widget.existing),
      fixedOverheadBytes: overheadBytesFor(sources),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.editing == null ? 'Choose an area' : 'Edit this area',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      if (size != _mapSize) {
                        _mapSize = size;
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _recomputeBounds(),
                        );
                      }
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          MapLibreMap(
                            key: ValueKey('picker-${_basemap.name}'),
                            styleString: _styleString,
                            initialCameraPosition: _initialCamera,
                            trackCameraPosition: true,
                            compassEnabled: false,
                            onMapCreated: (controller) =>
                                _map = controller,
                            onStyleLoadedCallback: _onStyleLoaded,
                            onCameraIdle: _recomputeBounds,
                          ),
                          const IgnorePointer(child: _FrameOverlay()),
                        ],
                      );
                    },
                  ),
                ),
                _buildPanel(theme),
              ],
            ),
    );
  }

  Future<void> _onStyleLoaded() async {
    await _frameEditedArea();
    await _recomputeBounds();
  }

  Widget _buildPanel(ThemeData theme) {
    final estimate = _estimate;
    final ceiling = detailCeilingFor(_currentSources);
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final kind in BasemapKind.values)
                      if (kind.supportsOfflineAreas)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(kind.label),
                            selected: _basemap == kind,
                            onSelected: (_) => setState(() {
                              _basemap = kind;
                              // Streets has no imagery, so it stops at the
                              // Standard level. Leaving Detailed selected but
                              // disabled would strand the control.
                              final ceiling =
                                  detailCeilingFor(_currentSources);
                              if (_detail.zoom > ceiling) {
                                _detail = AreaDetail.standard;
                              }
                              final bounds = _frameBounds;
                              if (bounds != null) {
                                _estimate = _estimateFor(bounds);
                              }
                            }),
                          ),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<AreaDetail>(
                segments: [
                  for (final detail in AreaDetail.values)
                    ButtonSegment(
                      value: detail,
                      label: Text(detail.label),
                      enabled: detail.zoom <= ceiling,
                    ),
                ],
                selected: {_detail},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => setState(() {
                  _detail = selection.first;
                  final bounds = _frameBounds;
                  if (bounds != null) _estimate = _estimateFor(bounds);
                }),
              ),
              const SizedBox(height: 6),
              Text(_detail.blurb, style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              _EstimateLine(
                estimate: estimate,
                theme: theme,
                editing: widget.editing != null,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  // Nothing left to fetch still leaves the area's own extent
                  // and detail level to change, so an edit stays available
                  // where a fresh download would have nothing to do.
                  onPressed: estimate == null ||
                          (estimate.newTiles == 0 && widget.editing == null)
                      ? null
                      : _confirm,
                  icon: const Icon(Icons.download),
                  label: Text(_confirmLabel(estimate)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _confirmLabel(SizeEstimate? estimate) {
    if (widget.editing != null) return 'Update this area';
    return estimate != null && estimate.newTiles == 0
        ? 'Already saved'
        : 'Save this area';
  }

  Future<void> _confirm() async {
    final bounds = _frameBounds;
    final estimate = _estimate;
    if (bounds == null || estimate == null) return;

    final editing = widget.editing;
    final centre = _centreOf(bounds);
    final controller = TextEditingController(
      text: editing?.name ??
          '${centre.latitude.toStringAsFixed(2)}, '
              '${centre.longitude.toStringAsFixed(2)}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(editing == null ? 'Save this area' : 'Update this area'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'So you can find it in the list later',
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${_basemap.label} · ${_detail.label} · '
              '${estimate.newTiles == 0 ? 'nothing new to download' : 'about '
                  '${formatBytes(estimate.newBytes)} to download'}.\n\n'
              '${editing == null ? '' : 'This replaces ${editing.name} as it '
                  'was saved. Tiles it already holds inside the new extent are '
                  'kept, and the old copy goes once the download finishes.\n\n'}'
              'The estimate is approximate. Tiles vary in size with how much '
              'is in them, and it comes in under where provincial imagery '
              'does not cover part of the area. Downloading over mobile data '
              'can be expensive.',
              style: const TextStyle(height: 1.35),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(editing == null ? 'Download' : 'Update'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final name = controller.text.trim();
    Navigator.pop(
      context,
      AreaDownloadRequest(
        name: name.isEmpty ? 'Saved area' : name,
        basemap: _basemap,
        bounds: bounds,
        maxZoom: _effectiveMaxZoom,
        estimatedBytes: estimate.newBytes,
      ),
    );
  }
}

class _EstimateLine extends StatelessWidget {
  const _EstimateLine({
    required this.estimate,
    required this.theme,
    this.editing = false,
  });

  final SizeEstimate? estimate;
  final ThemeData theme;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final value = estimate;
    if (value == null) {
      return Text('Measuring the area…', style: theme.textTheme.bodyMedium);
    }
    if (value.newTiles == 0) {
      return Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // Shrinking an area, or lowering its detail, needs no new tiles.
              // Saying it is "already saved" would read as nothing to do, when
              // what is on offer is trading disk space for a smaller area.
              editing
                  ? 'Nothing new to download. This device already holds the '
                      'tiles for this extent and detail level.'
                  : 'You already have this area saved at this detail level.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'About ${formatBytes(value.newBytes)} to download',
          style: theme.textTheme.titleMedium,
        ),
        if (value.overlapsExisting)
          Text(
            '${formatBytes(value.sharedBytes)} of this area overlaps '
            'something you already saved, so it is not downloaded again.',
            style: theme.textTheme.bodySmall,
          ),
        if (value.newBytes > _largeDownloadBytes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'That is a big download. A smaller area or a lower detail '
                    'level will cost a lot less, and imagery quadruples in '
                    'size with every step up.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Dims everything outside the rectangle that will be saved.
class _FrameOverlay extends StatelessWidget {
  const _FrameOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FramePainter(
        accent: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  const _FramePainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromLTRB(
      _frameInsetX,
      _frameInsetTop,
      size.width - _frameInsetX,
      size.height - _frameInsetBottom,
    );
    final shade = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(frame),
    );
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.accent != accent;
}
