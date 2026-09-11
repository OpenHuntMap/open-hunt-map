import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'import_export.dart';
import 'waypoint_category.dart';
import 'waypoint_editor.dart';
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

/// A header row in the grouped list.
class _Section {
  const _Section(this.category, this.count);
  final WaypointCategory category;
  final int count;
}

class _WaypointsPageState extends State<WaypointsPage> {
  final _transfer = WaypointImportExport();
  var _loading = true;

  /// Null means every category. The filter doubles as the export selection,
  /// which is how "export a subset" works without a second selection mode to
  /// learn: what you can see is what leaves.
  WaypointCategory? _category;
  String? _tag;

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

  List<Waypoint> get _visible => widget.store.items
      .where((item) => _category == null || item.category == _category)
      .where((item) => _tag == null || item.tags.contains(_tag))
      .toList();

  bool get _filtered => _category != null || _tag != null;

  /// Headers interleaved with waypoints, sorted by category then name.
  ///
  /// Sorted by the enum's own order rather than alphabetically, so the list
  /// reads in the order the category chips do and the two stay recognisable as
  /// the same set.
  List<Object> get _rows {
    final items = _visible
      ..sort((a, b) {
        final byCategory = a.category.index.compareTo(b.category.index);
        return byCategory != 0
            ? byCategory
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final rows = <Object>[];
    WaypointCategory? current;
    for (final item in items) {
      if (item.category != current) {
        current = item.category;
        rows.add(
          _Section(
            current,
            items.where((other) => other.category == current).length,
          ),
        );
      }
      rows.add(item);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waypoints'),
        actions: [
          PopupMenuButton<WaypointFormat>(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            enabled: visible.isNotEmpty,
            onSelected: (format) => _transfer.share(visible, format),
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  _filtered
                      ? 'Exports the ${visible.length} shown'
                      : 'Exports all ${visible.length}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: WaypointFormat.gpx,
                child: Text('GPX — Garmin, CalTopo, onX'),
              ),
              const PopupMenuItem(
                value: WaypointFormat.kml,
                child: Text('KML — Google Earth, folders per category'),
              ),
              const PopupMenuItem(
                value: WaypointFormat.geoJson,
                child: Text('GeoJSON — keeps everything, for backup'),
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
      body: _loading
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
          : Column(
              children: [
                _filterBar(),
                if (visible.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nothing matches this filter.'),
                      ),
                    ),
                  )
                else
                  Expanded(child: _list()),
              ],
            ),
    );
  }

  Widget _filterBar() {
    final counts = widget.store.categoryCounts;
    final tags = widget.store.tagsInUse;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          FilterChip(
            label: Text('All ${widget.store.items.length}'),
            selected: !_filtered,
            onSelected: (_) => setState(() {
              _category = null;
              _tag = null;
            }),
          ),
          // Only categories in use, so the row does not open with fifteen
          // chips of which twelve match nothing.
          for (final category in WaypointCategory.values)
            if (counts[category] case final count?) ...[
              const SizedBox(width: 8),
              FilterChip(
                avatar: Icon(category.icon, size: 18, color: category.colour),
                label: Text('${category.label} $count'),
                selected: _category == category,
                onSelected: (on) =>
                    setState(() => _category = on ? category : null),
              ),
            ],
          for (final tag in tags) ...[
            const SizedBox(width: 8),
            FilterChip(
              avatar: const Icon(Icons.label_outline, size: 16),
              label: Text(tag),
              selected: _tag == tag,
              onSelected: (on) => setState(() => _tag = on ? tag : null),
            ),
          ],
        ],
      ),
    );
  }

  Widget _list() {
    final rows = _rows;
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _Section(:final category, :final count) => _header(category, count),
        final Waypoint waypoint => _row(waypoint),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _header(WaypointCategory category, int count) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
    child: Row(
      children: [
        Icon(category.icon, size: 18, color: category.colour),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${category.label} · $count',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        IconButton(
          tooltip: 'Delete all ${category.label}',
          icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          onPressed: () => _deleteCategory(category),
        ),
      ],
    ),
  );

  Widget _row(Waypoint waypoint) {
    final isTrack = waypoint.track.isNotEmpty;
    final where = isTrack
        ? '${waypoint.track.length} track point(s)'
        : '${waypoint.latitude.toStringAsFixed(5)}, '
              '${waypoint.longitude.toStringAsFixed(5)}';
    final tags = waypoint.tags.isEmpty
        ? ''
        : '\n${waypoint.tags.map((tag) => '#$tag').join(' ')}';
    final subtitle = waypoint.notes.isEmpty
        ? '$where$tags'
        : '$where\n${waypoint.notes}$tags';
    return ListTile(
      // The saved colour, not the category's, because that is what the map
      // draws and the two lists have to be recognisably the same waypoints.
      leading: Icon(
        isTrack ? Icons.route : waypoint.category.icon,
        color: waypoint.displayColour,
      ),
      title: Text(waypoint.name),
      subtitle: Text(subtitle),
      isThreeLine: waypoint.notes.isNotEmpty || waypoint.tags.isNotEmpty,
      // The whole row, because a coordinate pair in a list is useless until you
      // can see where it is, so that is what tapping one should do. The explicit
      // button stays because nothing else on this row hints that it is tappable.
      onTap: () => _reveal(waypoint),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Show on map',
            icon: const Icon(Icons.travel_explore),
            onPressed: () => _reveal(waypoint),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (choice) => switch (choice) {
              'edit' => _edit(waypoint),
              _ => _delete(waypoint),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
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

  Future<void> _edit(Waypoint waypoint) async {
    final edited = await showWaypointEditor(
      context,
      existing: waypoint,
      knownTags: widget.store.tagsInUse,
      isNew: false,
    );
    if (edited == null) return;
    await widget.store.update(edited);
    if (mounted) setState(() {});
  }

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

  /// Clearing a whole category asks first, then still offers an undo.
  ///
  /// Both, not one or the other: the confirmation is because this removes work
  /// that took a season to collect, and the undo is because a confirmation
  /// dialog is something people dismiss on reflex.
  Future<void> _deleteCategory(WaypointCategory category) async {
    final doomed = widget.store.items
        .where((item) => item.category == category)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $doomed ${category.label} waypoint(s)?'),
        content: const Text(
          'This removes every waypoint in the category. You will get one '
          'chance to undo it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // The whole list, so undo restores the original order rather than appending
    // the deleted ones at the end.
    final before = widget.store.items.toList();
    final removed = await widget.store.deleteWhere(
      (item) => item.category == category,
    );
    if (!mounted) return;
    setState(() {
      if (_category == category) _category = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted ${removed.length} ${category.label}.'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await widget.store.replaceAll(before);
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _add() async {
    final location = widget.suggestedLocation;
    final draft = Waypoint(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: 'Waypoint',
      latitude: location.latitude,
      longitude: location.longitude,
      notes: '',
      createdAt: DateTime.now(),
      // Opens on whatever the filter is showing: adding three stands in a row
      // should not mean picking "Tree stand" three times.
      category: _category ?? WaypointCategory.other,
      tags: _tag == null ? const [] : [_tag!],
    );
    final saved = await showWaypointEditor(
      context,
      existing: draft,
      knownTags: widget.store.tagsInUse,
      isNew: true,
    );
    if (saved == null) return;
    await widget.store.add(saved);
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
