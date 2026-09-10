import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../data/models.dart';
import '../data/province_loader.dart';
import '../map/basemap.dart';
import 'area_picker_page.dart';
import 'basemap_area_store.dart';
import 'offline_pack_store.dart';
import 'pack_installer.dart';
import 'tile_math.dart';

/// Asks the map to outline the saved areas and frame one of them.
class OfflineAreaReveal {
  const OfflineAreaReveal({required this.focus, required this.areas});

  final BasemapArea focus;
  final List<BasemapArea> areas;
}

/// The actions a saved area offers beyond showing it on the map.
enum _AreaAction { resume, edit, rename, delete }

class OfflinePage extends StatefulWidget {
  const OfflinePage({super.key, required this.camera, required this.basemap});

  /// Where the map is looking, so the area picker opens on the same place
  /// rather than making the user find it again.
  final CameraPosition camera;
  final BasemapKind basemap;

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  final _loader = ProvinceLoader();
  final _installer = PackInstaller();
  // Shared, so a download that is already running is reported here rather than
  // started a second time.
  final _areaStore = BasemapAreaStore.instance;
  StreamSubscription<AreaDownloadProgress?>? _areaProgressSub;
  List<Province> _provinces = const [];
  Set<String> _installed = {};
  final Map<String, double?> _downloadProgress = {};
  final Set<String> _busy = {};
  var _loading = true;

  List<BasemapArea> _areas = const [];
  int? _diskBytes;
  AreaDownloadProgress? _areaProgress;
  String? _areaDownloadName;
  final Set<int> _areaBusy = {};

  @override
  void initState() {
    super.initState();
    // Pick up a download started before this screen was opened, or before it was
    // last closed, so leaving and coming back shows progress instead of an area
    // that looks abandoned.
    _areaProgress = _areaStore.latestProgress;
    _areaDownloadName = _areaStore.downloadingName;
    _areaProgressSub = _areaStore.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        _areaProgress = progress;
        _areaDownloadName = _areaStore.downloadingName;
      });
      if (progress == null) _loadAreas();
    });
    _load();
  }

  Future<void> _load() async {
    final provinces = await _loader.loadProvinces();
    final installed = await installedOfflinePackIds();
    if (!mounted) return;
    setState(() {
      _provinces = provinces;
      _installed = installed;
      _loading = false;
    });
    await _loadAreas();
  }

  Future<void> _loadAreas() async {
    if (!offlinePackStorageSupported) return;
    try {
      final areas = await _areaStore.list();
      final disk = await _areaStore.diskBytes();
      if (!mounted) return;
      setState(() {
        _areas = areas;
        _diskBytes = disk;
      });
    } on Object {
      // No offline database yet, or a platform without one. The section simply
      // shows nothing saved.
    }
  }

  @override
  void dispose() {
    _installer.close();
    _areaProgressSub?.cancel();
    _areaStore.releaseIfIdle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline packs')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Province data packs',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Crown land, parks, WMU boundaries, municipal boundaries, '
                  'land-use policies and hunting seasons all live in these '
                  'packs. Download one and the province works fully offline; '
                  'redownload it to pick up refreshed data without updating '
                  'the app.',
                  style: TextStyle(height: 1.35),
                ),
                if (!offlinePackStorageSupported) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Pack Download and Import require Android or iOS '
                    '(or a future desktop MapLibre build).',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: 20),
                ..._provinces.map(_buildProvinceCard),
                const SizedBox(height: 28),
                _buildAreasSection(),
              ],
            ),
    );
  }

  Widget _buildAreasSection() {
    final theme = Theme.of(context);
    final grouped = <BasemapKind, List<BasemapArea>>{};
    for (final area in _areas) {
      grouped.putIfAbsent(area.basemap, () => []).add(area);
    }
    final disk = _diskBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Basemap areas', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'The Streets, Satellite and Hybrid basemaps stream their tiles, so '
          'they go blank without a signal. Save the areas you actually go '
          'and those keep working offline. The Offline (simple) basemap needs '
          'nothing saved; it draws a plain background at any zoom.',
          style: TextStyle(height: 1.35),
        ),
        const SizedBox(height: 14),
        if (disk != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: Text('${formatBytes(disk)} of map tiles on this device'),
              subtitle: Text(
                _areas.isEmpty
                    ? 'Tiles the app has looked at recently, kept in a '
                        'temporary cache that clears itself.'
                    : '${_areas.length} saved '
                        '${_areas.length == 1 ? 'area' : 'areas'}, plus '
                        'recently viewed tiles. Areas that overlap share their '
                        'tiles, so the sizes below can add up to more than '
                        'this.',
              ),
              isThreeLine: _areas.isNotEmpty,
            ),
          ),
        if (_areaProgress != null) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Downloading ${_areaDownloadName ?? 'area'}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _areaProgress!.fraction == 0
                        ? null
                        : _areaProgress!.fraction,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${formatBytes(_areaProgress!.bytes)} downloaded'
                    '${_areaProgress!.tilesTotal > 0 ? ' · '
                        '${_areaProgress!.tilesDone} of '
                        '${_areaProgress!.tilesTotal} tiles' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You can leave this screen; the download keeps going. '
                    'Free tile servers throttle heavy use, so this can slow '
                    'right down, and you can resume it later if it stops.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (_areas.isEmpty && _areaProgress == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No areas saved yet.'),
          ),
        for (final kind in BasemapKind.values)
          if (grouped[kind] != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Row(
                children: [
                  Icon(kind.icon, size: 18),
                  const SizedBox(width: 8),
                  Text(kind.label, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    formatBytes(
                      grouped[kind]!.fold(0, (sum, a) => sum + a.sizeBytes),
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            ...grouped[kind]!.map(_buildAreaCard),
          ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: _areaProgress != null || !offlinePackStorageSupported
                ? null
                : _pickArea,
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Save an area for offline use'),
          ),
        ),
      ],
    );
  }

  Widget _buildAreaCard(BasemapArea area) {
    final busy = _areaBusy.contains(area.regionId);
    final downloading = _areaProgress != null;
    return Card(
      child: ListTile(
        title: Text(area.name),
        subtitle: Text(
          [
            formatBytes(area.sizeBytes),
            'to zoom ${area.maxZoom}',
            if (!area.complete) 'part saved — tap resume to finish it',
          ].join(' · '),
        ),
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            // Five icon buttons fit a phone only by squeezing the name and size
            // into two wrapped lines each, and "edit the extent" and "rename"
            // have no icons that tell them apart. Only the one action wanted at
            // a glance stays a button; the rest get words in a menu.
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Show on map',
                    icon: const Icon(Icons.crop_free),
                    onPressed: () => Navigator.pop(
                      context,
                      OfflineAreaReveal(focus: area, areas: _areas),
                    ),
                  ),
                  PopupMenuButton<_AreaAction>(
                    tooltip: 'More actions',
                    // One download at a time: they compete for the same rate
                    // limited tile servers, and running two makes both crawl.
                    enabled: !downloading,
                    onSelected: (action) => switch (action) {
                      _AreaAction.resume => _resumeArea(area),
                      _AreaAction.edit => _editArea(area),
                      _AreaAction.rename => _renameArea(area),
                      _AreaAction.delete => _deleteArea(area),
                    },
                    itemBuilder: (context) => [
                      if (!area.complete)
                        const PopupMenuItem(
                          value: _AreaAction.resume,
                          child: ListTile(
                            leading: Icon(Icons.refresh),
                            title: Text('Resume download'),
                          ),
                        ),
                      const PopupMenuItem(
                        value: _AreaAction.edit,
                        child: ListTile(
                          leading: Icon(Icons.crop),
                          title: Text('Edit extent and detail'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: _AreaAction.rename,
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Rename'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: _AreaAction.delete,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _renameArea(BasemapArea area) async {
    final controller = TextEditingController(text: area.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename area'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == area.name) return;
    try {
      await _areaStore.rename(area, name);
      await _loadAreas();
    } catch (error) {
      if (!mounted) return;
      _showMessage('Could not rename the area: $error');
    }
  }

  Future<void> _resumeArea(BasemapArea area) async {
    setState(() {
      _areaDownloadName = area.name;
      _areaProgress = const AreaDownloadProgress(
        fraction: 0,
        bytes: 0,
        tilesDone: 0,
        tilesTotal: 0,
      );
    });
    try {
      await _areaStore.resume(area);
      if (!mounted) return;
      await _loadAreas();
      _showMessage('${area.name} finished downloading.');
    } catch (error) {
      if (!mounted) return;
      await _loadAreas();
      _showMessage('Could not finish ${area.name}: $error');
    }
  }

  Future<void> _editArea(BasemapArea area) async {
    final request = await Navigator.push<AreaDownloadRequest>(
      context,
      MaterialPageRoute(
        builder: (_) => AreaPickerPage(
          initialCamera: widget.camera,
          basemap: area.basemap,
          existing: _areas,
          editing: area,
        ),
      ),
    );
    if (request == null || !mounted) return;

    setState(() {
      _areaDownloadName = request.name;
      _areaProgress = const AreaDownloadProgress(
        fraction: 0,
        bytes: 0,
        tilesDone: 0,
        tilesTotal: 0,
      );
    });
    try {
      await _areaStore.replace(
        area,
        name: request.name,
        basemap: request.basemap,
        bounds: request.bounds,
        maxZoom: request.maxZoom,
      );
      if (!mounted) return;
      await _loadAreas();
      _showMessage('${request.name} updated.');
    } catch (error) {
      if (!mounted) return;
      await _loadAreas();
      _showMessage('Could not update ${area.name}: $error');
    }
  }

  Future<void> _pickArea() async {
    final request = await Navigator.push<AreaDownloadRequest>(
      context,
      MaterialPageRoute(
        builder: (_) => AreaPickerPage(
          initialCamera: widget.camera,
          basemap: widget.basemap,
          existing: _areas,
        ),
      ),
    );
    if (request == null || !mounted) return;
    await _downloadArea(request);
  }

  Future<void> _downloadArea(AreaDownloadRequest request) async {
    setState(() {
      _areaDownloadName = request.name;
      _areaProgress = const AreaDownloadProgress(
        fraction: 0,
        bytes: 0,
        tilesDone: 0,
        tilesTotal: 0,
      );
    });
    try {
      await _areaStore.download(
        name: request.name,
        basemap: request.basemap,
        bounds: request.bounds,
        maxZoom: request.maxZoom,
        onProgress: (progress) {
          if (mounted) setState(() => _areaProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _areaProgress = null;
        _areaDownloadName = null;
      });
      await _loadAreas();
      _showMessage('${request.name} saved for offline use.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _areaProgress = null;
        _areaDownloadName = null;
      });
      await _loadAreas();
      _showMessage('Could not finish the download: $error');
    }
  }

  Future<void> _deleteArea(BasemapArea area) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${area.name}?'),
        content: Text(
          'The ${area.basemap.label} basemap will need a connection in this '
          'area again. Tiles shared with another saved area are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _areaBusy.add(area.regionId));
    try {
      await _areaStore.delete(area.regionId);
    } catch (error) {
      _showMessage('Could not delete the area: $error');
    }
    if (!mounted) return;
    setState(() => _areaBusy.remove(area.regionId));
    await _loadAreas();
  }

  Widget _buildProvinceCard(Province province) {
    final id = province.id;
    final installed = _installed.contains(id);
    final busy = _busy.contains(id);
    final status = installed ? 'Downloaded' : 'Not downloaded';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(installed ? Icons.offline_pin : Icons.map_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        province.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(status),
                    ],
                  ),
                ),
              ],
            ),
            if (_downloadProgress.containsKey(id)) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _downloadProgress[id]),
              const SizedBox(height: 4),
              Text(
                _downloadProgress[id] == null
                    ? 'Downloading…'
                    : 'Downloading ${(_downloadProgress[id]! * 100).round()}%',
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy ||
                          !offlinePackStorageSupported ||
                          province.packUrl == null
                      ? null
                      : () => _download(province),
                  icon: Icon(installed ? Icons.refresh : Icons.download),
                  label: Text(installed ? 'Update' : 'Download'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !offlinePackStorageSupported
                      ? null
                      : () => _import(province),
                  icon: const Icon(Icons.file_open),
                  label: const Text('Import ZIP'),
                ),
                TextButton.icon(
                  onPressed:
                      busy || !installed ? null : () => _delete(province),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete local pack'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(Province province) async {
    _start(province.id, downloading: true);
    try {
      await _installer.download(
        province,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _downloadProgress[province.id] = progress);
        },
      );
      await _finishInstalled(province, 'Pack downloaded.');
    } catch (error) {
      _finishWithError(province.id, error);
    }
  }

  Future<void> _import(Province province) async {
    _start(province.id);
    try {
      final imported = await _installer.importZip(province);
      if (!imported) {
        _finish(province.id);
        return;
      }
      await _finishInstalled(province, 'Pack imported.');
    } catch (error) {
      _finishWithError(province.id, error);
    }
  }

  Future<void> _delete(Province province) async {
    _start(province.id);
    try {
      await deleteOfflinePack(province.id);
      if (!mounted) return;
      setState(() {
        _installed.remove(province.id);
        _busy.remove(province.id);
      });
      _showMessage('Local ${province.name} pack deleted.');
    } catch (error) {
      _finishWithError(province.id, error);
    }
  }

  void _start(String provinceId, {bool downloading = false}) {
    setState(() {
      _busy.add(provinceId);
      if (downloading) _downloadProgress[provinceId] = null;
    });
  }

  Future<void> _finishInstalled(Province province, String message) async {
    final installed = await installedOfflinePackIds();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _busy.remove(province.id);
      _downloadProgress.remove(province.id);
    });
    _showMessage(message);
  }

  void _finish(String provinceId) {
    if (!mounted) return;
    setState(() {
      _busy.remove(provinceId);
      _downloadProgress.remove(provinceId);
    });
  }

  void _finishWithError(String provinceId, Object error) {
    _finish(provinceId);
    if (mounted) _showMessage('Pack operation failed: $error');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
