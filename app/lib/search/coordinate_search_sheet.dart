import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'coordinate_parser.dart';

/// Opens the coordinate box, returning the point to go to or null if dismissed.
Future<Coordinate?> showCoordinateSearch(BuildContext context) =>
    showModalBottomSheet<Coordinate>(
      context: context,
      showDragHandle: true,
      // The field pushes a keyboard up, and without this the sheet is capped
      // near half the screen and the Go button ends up behind it.
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: CoordinateSearchPanel(
            onAccept: (coordinate) => Navigator.pop(context, coordinate),
          ),
        ),
      ),
    );

/// The coordinate box.
///
/// Parses as you type rather than on submit, and reads the result back as plain
/// decimal degrees. That read-back is the point: the mistake people actually
/// make is pasting a coordinate that lost its minus sign somewhere, and seeing
/// "45.086428, 75.786970" next to a note that it is in Uzbekistan is the only
/// warning that costs nothing.
class CoordinateSearchPanel extends StatefulWidget {
  const CoordinateSearchPanel({super.key, required this.onAccept});

  final ValueChanged<Coordinate> onAccept;

  @override
  State<CoordinateSearchPanel> createState() => _CoordinateSearchPanelState();
}

class _CoordinateSearchPanelState extends State<CoordinateSearchPanel> {
  final _controller = TextEditingController();
  CoordinateResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reparse(String text) =>
      setState(() => _result = parseCoordinate(text));

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      setState(() => _result = const CoordinateError('The clipboard is empty.'));
      return;
    }
    _controller.text = text.trim();
    _reparse(_controller.text);
  }

  void _submit() {
    final result = _result;
    if (result is Coordinate) widget.onAccept(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _result is Coordinate;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ListTile(
              title: Text('Go to a coordinate'),
              subtitle: Text(
                'Paste one from anywhere. Place-name search is not in this '
                'build yet.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.go,
                // Not TextInputType.number: every notation here needs letters,
                // degree marks or a whole URL, so the plain keyboard is the
                // only one that can type them.
                keyboardType: TextInputType.text,
                onChanged: _reparse,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Coordinate or map link',
                  hintText: '45.086428, -75.786970',
                  suffixIcon: IconButton(
                    tooltip: 'Paste',
                    icon: const Icon(Icons.content_paste),
                    onPressed: _paste,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _feedback(theme),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    // Disabled until something parsed, so the button itself
                    // says whether the input was understood.
                    onPressed: ready ? _submit : null,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Go'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedback(ThemeData theme) => switch (_result) {
    null => Text(
      'Decimal degrees, degrees and decimal minutes, '
      'degrees-minutes-seconds, a UTM grid reference, or a Google Maps link.',
      style: theme.textTheme.bodySmall,
    ),
    CoordinateError(:final message) => _Line(
      icon: Icons.error_outline,
      colour: theme.colorScheme.error,
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    ),
    Coordinate(
      :final latitude,
      :final longitude,
      :final format,
      :final note,
    ) =>
      _Line(
        icon: Icons.place_outlined,
        colour: theme.colorScheme.primary,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${latitude.toStringAsFixed(6)}, '
              '${longitude.toStringAsFixed(6)}',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              note == null ? 'Read as $format.' : 'Read as $format. $note',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
  };
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.colour,
    required this.child,
  });

  final IconData icon;
  final Color colour;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: colour),
      const SizedBox(width: 8),
      Expanded(child: child),
    ],
  );
}
