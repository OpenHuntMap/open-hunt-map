import 'package:flutter/material.dart';

import '../tracks/track_math.dart';
import '../tracks/track_preview.dart';
import '../tracks/track_style.dart';
import 'legacy_categories.dart';
import 'waypoint_colour.dart';
import 'waypoint_icon.dart';
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
  late WaypointIcon _icon;
  late WaypointColour? _colour;
  late List<String> _tags;
  late TrackStroke _stroke;
  late TrackMarker _marker;

  /// Collapsed to start with. Nineteen chips on show would read as a list the
  /// user is expected to work through, which is the opposite of what they are.
  var _showSuggestions = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing.name);
    _notes = TextEditingController(text: widget.existing.notes);
    _icon = widget.existing.icon;
    _colour = widget.existing.colour;
    _tags = [...widget.existing.tags];
    _stroke = widget.existing.stroke;
    _marker = widget.existing.marker;
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _isLine => widget.existing.isTrack;

  void _save() {
    final name = _name.text.trim();
    widget.onSave(
      widget.existing.copyWith(
        name: name.isEmpty ? widget.existing.name : name,
        notes: _notes.text.trim(),
        icon: _icon,
        tags: _tags,
        colour: _colour,
        clearColour: _colour == null,
        stroke: _stroke,
        marker: _marker,
      ),
    );
  }

  /// What the line will actually be drawn in, which is not [_colour]: null there
  /// means the glyph's own colour, and a preview has to resolve that to see it.
  Color get _lineColour => _colour?.value ?? _icon.colour;

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
    // A suggestion the user has adopted is their tag now, and showing it in
    // both places would say it was still only an example.
    final unusedSuggestions = suggestedTags
        .where(
          (tag) => !_tags.contains(tag) && !widget.knownTags.contains(tag),
        )
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
              title: Text(
                switch ((_isLine, widget.isNew)) {
                  (true, _) => 'Edit track',
                  (false, true) => 'New waypoint',
                  (false, false) => 'Edit waypoint',
                },
              ),
              // A track's own start coordinate is not what identifies it, so it
              // gets its length and how long it took instead.
              subtitle: Text(
                _isLine
                    ? describeTrack(widget.existing.track)
                    : '${widget.existing.latitude.toStringAsFixed(5)}, '
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
            _label(theme, 'Icon'),
            // Sectioned, because thirty pictograms in one wall is unreadable.
            // The sections are the picker's only job: nothing downstream reads
            // a glyph's group, and a fishing glyph on a stand is a legitimate
            // choice rather than a mistake to be prevented.
            for (final entry in WaypointIcon.byGroup.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Text(
                  entry.key.label,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final icon in entry.value)
                      ChoiceChip(
                        selected: icon == _icon,
                        // Material draws the selected checkmark inside the
                        // avatar behind a scrim, which turns the glyph into an
                        // unreadable grey disc — and the glyph is the only
                        // reason this chip has an avatar. The filled container
                        // says "selected" on its own.
                        showCheckmark: false,
                        // In the glyph's own colour, because that is what the
                        // waypoint will be drawn in unless a colour is chosen
                        // below, and a picker that hid that would be asking
                        // the user to pick a colour blind.
                        avatar: Icon(icon.icon, size: 18, color: icon.colour),
                        label: Text(icon.label),
                        onSelected: (_) => setState(() => _icon = icon),
                      ),
                  ],
                ),
              ),
            ],
            _label(theme, 'Colour'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Following the glyph is a real choice and not the same as
                  // picking the colour the glyph happens to carry: this swatch
                  // repaints itself when the glyph above changes, and a
                  // waypoint set this way follows.
                  _Swatch(
                    colour: _icon.colour,
                    label: "The icon's own colour",
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
            // Only for lines. A point has no stroke to pattern and no direction
            // to mark, and offering it either would suggest otherwise.
            if (_isLine) ...[
              _label(theme, 'Line'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TrackPreview(
                  colour: _lineColour,
                  stroke: _stroke,
                  marker: _marker,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final stroke in TrackStroke.values)
                      ChoiceChip(
                        selected: stroke == _stroke,
                        label: Text(stroke.label),
                        onSelected: (_) => setState(() => _stroke = stroke),
                      ),
                  ],
                ),
              ),
              _label(theme, 'Direction'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final marker in TrackMarker.values)
                      ChoiceChip(
                        selected: marker == _marker,
                        // See the category chips: the checkmark would sit on top
                        // of the shape being chosen.
                        showCheckmark: false,
                        avatar: marker.icon == null
                            ? null
                            : Icon(marker.icon, size: 18),
                        label: Text(marker.label),
                        onSelected: (_) => setState(() => _marker = marker),
                      ),
                  ],
                ),
              ),
            ],
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
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showSuggestions = !_showSuggestions),
                icon: Icon(
                  _showSuggestions ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: const Text('Example tags'),
              ),
            ),
            if (_showSuggestions) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Built-in examples, not tags you have made. Take any that '
                  'suit how you organise your spots and ignore the rest.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in unusedSuggestions)
                      ActionChip(
                        avatar: const Icon(Icons.lightbulb_outline, size: 16),
                        label: Text(tag),
                        onPressed: () => setState(
                          () => _tags = normaliseTags([..._tags, tag]),
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
