import 'package:flutter/material.dart';

import 'overlay_controller.dart';

class LayerPanel extends StatelessWidget {
  const LayerPanel({
    super.key,
    required this.controller,
    required this.trackArrows,
  });

  final OverlayController controller;

  /// Whether saved tracks are drawn with direction arrows along them.
  ///
  /// Lives here rather than on a settings screen because this sheet is already
  /// the answer to "what is on my map and how does it look", and a notifier
  /// rather than a value and a callback so the checkbox redraws on tap: the
  /// sheet is built once by [showModalBottomSheet] and does not rebuild when the
  /// map shell does.
  final ValueNotifier<bool> trackArrows;

  static const labels = {
    'crown_land': 'Crown land parcels',
    'crown_disposition': 'Leased & occupied Crown land',
    'municipal_forest': 'Municipal & county forests',
    'conservation_authority': 'Conservation authority land (permit)',
    'first_nations': 'Reserves (First Nation permission)',
    'parks': 'Provincial parks',
    'conservation_reserve': 'Conservation reserves (hunting permitted)',
    'game_preserve': 'Crown game preserves (no hunting)',
    'federal_closure': 'Wildlife areas & bird sanctuaries (no hunting)',
    'defence_land': 'Defence property (no hunting)',
    'land_use_plan': 'Far North & community land use plans',
    'wmu': 'Wildlife management units',
    'sunday_gun': 'Sunday gun hunting permitted',
    'municipalities': 'Municipalities (bylaws)',
  };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ConstrainedBox(
          // The layer list has outgrown a short sheet, and on a landscape
          // tablet it is taller than the screen. Cap the sheet and scroll the
          // list rather than letting the last few layers fall off the bottom
          // where nothing can reach them.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Map layers',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 2),
                    const Text(
                      'Tap a colour to change it.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  // Shrink-wrapped so a province with few layers still gets a
                  // sheet sized to its content instead of a fixed tall one.
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    ...OverlayController.layerOrder.map(
                      (id) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(labels[id] ?? id),
                        value: controller.visibility[id] ?? false,
                        onChanged: (value) =>
                            controller.setVisible(id, value ?? false),
                        secondary: _Swatch(
                          color: controller.colorFor(id),
                          customised: controller.isCustomColor(id),
                          onTap: () => _pickColor(context, id),
                        ),
                      ),
                    ),
                    const Divider(height: 24),
                    Text(
                      'Your tracks',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: trackArrows,
                      builder: (context, on, _) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Direction arrows'),
                        subtitle: const Text(
                          'Arrows along each track showing which way it runs.',
                        ),
                        value: on,
                        onChanged: (value) => trackArrows.value = value ?? true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickColor(BuildContext context, String id) async {
    final selected = await showDialog<String?>(
      context: context,
      builder: (context) => _ColorPickerDialog(
        title: labels[id] ?? id,
        current: controller.colorFor(id),
        defaultColor: OverlayController.defaultColorFor(id),
        customised: controller.isCustomColor(id),
      ),
    );
    if (selected == null) return;
    // An empty string is the dialog's way of saying "back to default", which is
    // distinct from null meaning the user dismissed without choosing.
    await controller.setColor(id, selected.isEmpty ? null : selected);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.customised,
    required this.onTap,
  });

  final String color;
  final bool customised;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: customised ? 'Custom colour' : 'Default colour',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: parseHexColor(color),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.45),
                  width: 1.2,
                ),
              ),
              child: customised
                  ? const Icon(Icons.edit, size: 12, color: Colors.black54)
                  : null,
            ),
          ),
        ),
      );
}

class _ColorPickerDialog extends StatelessWidget {
  const _ColorPickerDialog({
    required this.title,
    required this.current,
    required this.defaultColor,
    required this.customised,
  });

  final String title;
  final String current;
  final String defaultColor;
  final bool customised;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: OverlayController.palette.map((hex) {
              final isCurrent =
                  hex.toUpperCase() == current.toUpperCase();
              return InkWell(
                onTap: () => Navigator.pop(context, hex),
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: parseHexColor(hex),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isCurrent
                          ? Colors.black87
                          : Colors.black.withValues(alpha: 0.3),
                      width: isCurrent ? 3 : 1,
                    ),
                  ),
                  child: isCurrent
                      ? const Icon(Icons.check, size: 18, color: Colors.white)
                      : null,
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          if (customised)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Reset to default'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      );
}

/// Parses `#RRGGBB` as used in the layer styles and MapLibre paint properties.
Color parseHexColor(String hex) {
  final cleaned = hex.replaceFirst('#', '').trim();
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null || cleaned.length != 6) return const Color(0xFF2E7D32);
  return Color(0xFF000000 | value);
}
