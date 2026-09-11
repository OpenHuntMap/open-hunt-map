import 'package:flutter/material.dart';

import 'waypoint_category.dart';
import 'waypoint_store.dart';

/// Opens the waypoint editor, returning the edited waypoint or null if cancelled.
///
/// One editor for both new and existing waypoints, because the fields are the
/// same and two of them would drift apart. [existing] decides which.
Future<Waypoint?> showWaypointEditor(
  BuildContext context, {
  required Waypoint existing,
  required List<String> knownTags,
  required bool isNew,
}) => showModalBottomSheet<Waypoint>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: WaypointEditor(
        existing: existing,
        knownTags: knownTags,
        isNew: isNew,
        onSave: (waypoint) => Navigator.pop(context, waypoint),
      ),
    ),
  ),
);

class WaypointEditor extends StatefulWidget {
  const WaypointEditor({
    super.key,
    required this.existing,
    required this.knownTags,
    required this.isNew,
    required this.onSave,
  });

  final Waypoint existing;

  /// Tags already in use, offered as chips. Typing the same tag twice with a
  /// different capitalisation is the main way a tag list turns to noise.
  final List<String> knownTags;

  final bool isNew;
  final ValueChanged<Waypoint> onSave;

  @override
  State<WaypointEditor> createState() => _WaypointEditorState();
}

class _WaypointEditorState extends State<WaypointEditor> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late WaypointCategory _category;
  late WaypointColour? _colour;
  late List<String> _tags;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing.name);
    _notes = TextEditingController(text: widget.existing.notes);
    _category = widget.existing.category;
    _colour = widget.existing.colour;
    _tags = [...widget.existing.tags];
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    widget.onSave(
      widget.existing.copyWith(
        name: name.isEmpty ? widget.existing.name : name,
        notes: _notes.text.trim(),
        category: _category,
        tags: _tags,
        colour: _colour,
        clearColour: _colour == null,
      ),
    );
  }

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a tag'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: const InputDecoration(
            hintText: 'ridge, north block, opening day',
            helperText: 'Commas separate several at once.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (added == null || !mounted) return;
    setState(
      () => _tags = normaliseTags([..._tags, ...added.split(',')]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unusedKnownTags = widget.knownTags
        .where((tag) => !_tags.contains(tag))
        .toList();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(widget.isNew ? 'New waypoint' : 'Edit waypoint'),
              subtitle: Text(
                '${widget.existing.latitude.toStringAsFixed(5)}, '
                '${widget.existing.longitude.toStringAsFixed(5)}',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _name,
                autofocus: widget.isNew,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Name',
                ),
              ),
            ),
            _label(theme, 'Category'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final category in WaypointCategory.values)
                    ChoiceChip(
                      selected: category == _category,
                      // The glyph is on the chip because it is the glyph that
                      // will be on the map, and picking a category blind and
                      // then discovering its icon is a worse way round.
                      avatar: Icon(
                        category.icon,
                        size: 18,
                        color: category == _category
                            ? null
                            : category.colour,
                      ),
                      label: Text(category.label),
                      onSelected: (_) => setState(() => _category = category),
                    ),
                ],
              ),
            ),
            _label(theme, 'Colour'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // "Follow the category" is a real choice and not the same as
                  // picking the category's current colour: this one keeps up if
                  // the category's default ever changes.
                  _Swatch(
                    colour: _category.colour,
                    label: 'Category',
                    selected: _colour == null,
                    onTap: () => setState(() => _colour = null),
                  ),
                  for (final colour in WaypointColour.values)
                    _Swatch(
                      colour: colour.value,
                      label: colour.label,
                      selected: _colour == colour,
                      onTap: () => setState(() => _colour = colour),
                    ),
                ],
              ),
            ),
            _label(theme, 'Tags'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: () => setState(
                        () => _tags = [..._tags]..remove(tag),
                      ),
                    ),
                  for (final tag in unusedKnownTags)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text(tag),
                      onPressed: () => setState(
                        () => _tags = normaliseTags([..._tags, tag]),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.label_outline, size: 16),
                    label: const Text('New tag'),
                    onPressed: _addTag,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Notes',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: Text(widget.isNew ? 'Save' : 'Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8),
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.colour,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color colour;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            // An outline on every swatch rather than only the selected one, so
            // white and black both stay visible against the sheet.
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.black26,
              width: selected ? 3 : 1,
            ),
          ),
          // A white tick disappears on the white and yellow swatches, so the
          // tick takes whichever of black or white the swatch can carry.
          child: selected
              ? Icon(
                  Icons.check,
                  size: 18,
                  color:
                      ThemeData.estimateBrightnessForColor(colour) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black87,
                )
              : null,
        ),
      ),
    ),
  );
}
