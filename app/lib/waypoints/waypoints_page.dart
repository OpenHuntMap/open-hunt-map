import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'import_export.dart';
import 'waypoint_store.dart';

class WaypointsPage extends StatefulWidget {
  const WaypointsPage({
    super.key,
    required this.store,
    required this.suggestedLocation,
  });

  final WaypointStore store;
  final LatLng suggestedLocation;

  @override
  State<WaypointsPage> createState() => _WaypointsPageState();
}

class _WaypointsPageState extends State<WaypointsPage> {
  final _transfer = WaypointImportExport();
  var _loading = true;

  @override
  void initState() {
    super.initState();
    widget.store.load().then((_) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (widget.store.unreadableFilePath case final path?) {
        _warnUnreadable(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waypoints'),
        actions: [
          PopupMenuButton<WaypointFormat>(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            onSelected: (format) => _transfer.share(widget.store.items, format),
            itemBuilder:
                (context) => const [
                  PopupMenuItem(
                    value: WaypointFormat.gpx,
                    child: Text('Export GPX'),
                  ),
                  PopupMenuItem(
                    value: WaypointFormat.kml,
                    child: Text('Export KML'),
                  ),
                  PopupMenuItem(
                    value: WaypointFormat.geoJson,
                    child: Text('Export GeoJSON'),
                  ),
                ],
          ),
          IconButton(
            tooltip: 'Import GPX, KML, or GeoJSON',
            icon: const Icon(Icons.file_open),
            onPressed: _import,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add here'),
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : widget.store.items.isEmpty
              ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No waypoints yet.\nAdd one at the last identified point '
                    'or current map center.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
              : ListView.builder(
                itemCount: widget.store.items.length,
                itemBuilder: (context, index) {
                  final waypoint = widget.store.items[index];
                  final isTrack = waypoint.track.isNotEmpty;
                  final locationSummary =
                      isTrack
                          ? '${waypoint.track.length} track point(s)'
                          : '${waypoint.latitude.toStringAsFixed(5)}, '
                              '${waypoint.longitude.toStringAsFixed(5)}';
                  final subtitle =
                      waypoint.notes.isEmpty
                          ? locationSummary
                          : '$locationSummary\n${waypoint.notes}';
                  return ListTile(
                    leading: Icon(isTrack ? Icons.route : Icons.location_on),
                    title: Text(waypoint.name),
                    subtitle: Text(subtitle),
                    isThreeLine: waypoint.notes.isNotEmpty,
                    // The whole row, because a coordinate pair in a list is
                    // useless until you can see where it is, so that is what
                    // tapping one should do. The explicit button stays because
                    // nothing else on this row hints that the row is tappable.
                    onTap: () => _reveal(waypoint),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Show on map',
                          icon: const Icon(Icons.travel_explore),
                          onPressed: () => _reveal(waypoint),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(waypoint),
                        ),
                      ],
                    ),
                  );
                },
              ),
    );
  }

  /// Hands the waypoint back to the map, which owns the camera.
  void _reveal(Waypoint waypoint) => Navigator.pop(context, waypoint);

  /// An empty list here would otherwise read as "you never saved anything".
  void _warnUnreadable(String path) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Your waypoint file could not be read'),
      content: Text(
        'This list is empty because the saved file could not be parsed, not '
        'because it was empty. Nothing has been deleted: the file was moved to '
        '$path so that saving new waypoints cannot overwrite it.\n\n'
        'If you were running a newer build of the app, going back to it should '
        'read the file again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  /// Deletes with an undo, because the button sits beside a tappable row and
  /// there is nowhere else a waypoint can be recovered from once it is gone.
  Future<void> _delete(Waypoint waypoint) async {
    final index = widget.store.items.indexWhere(
      (item) => item.id == waypoint.id,
    );
    await widget.store.delete(waypoint.id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted ${waypoint.name}.'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            final restored = [...widget.store.items];
            restored.insert(index.clamp(0, restored.length), waypoint);
            await widget.store.replaceAll(restored);
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _add() async {
    final name = TextEditingController(text: 'Waypoint');
    final notes = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('New waypoint'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
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
                child: const Text('Save'),
              ),
            ],
          ),
    );
    if (accepted != true) return;
    final location = widget.suggestedLocation;
    await widget.store.add(
      Waypoint(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim().isEmpty ? 'Waypoint' : name.text.trim(),
        latitude: location.latitude,
        longitude: location.longitude,
        notes: notes.text.trim(),
        createdAt: DateTime.now(),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    try {
      final imported = await _transfer.pickAndImport();
      if (imported == null) return;
      // Importing the same file twice used to double everything. Only our own
      // GeoJSON carries an id through an export, so this catches re-importing a
      // backup, which is the case that actually happens.
      final held = widget.store.items.map((item) => item.id).toSet();
      final fresh = imported
          .where((item) => !held.contains(item.id))
          .toList();
      await widget.store.replaceAll([...widget.store.items, ...fresh]);
      if (!mounted) return;
      setState(() {});
      final skipped = imported.length - fresh.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            skipped == 0
                ? 'Imported ${fresh.length} waypoint(s).'
                : 'Imported ${fresh.length}, skipped $skipped already here.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }
}
