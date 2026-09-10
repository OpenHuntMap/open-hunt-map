import 'package:flutter/material.dart';

import 'basemap.dart';

/// The basemap chooser shown in a bottom sheet.
///
/// A widget of its own rather than a closure inside the map shell, so the
/// "is every option actually reachable" case can be tested. It was not: on a
/// short landscape screen the sheet capped near half the height and the last
/// basemap sat below the bottom edge with no way to scroll to it.
class BasemapPanel extends StatelessWidget {
  const BasemapPanel({
    super.key,
    required this.selected,
    required this.onPick,
  });

  final BasemapKind selected;
  final ValueChanged<BasemapKind> onPick;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // Leaves the sheet content-sized when it fits, and scrollable when it does
      // not, instead of letting a fixed cap decide.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('Basemap'),
            subtitle: Text(
              'Streets and satellite need network. '
              'Offline works without tiles.',
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final kind in BasemapKind.values)
                  ListTile(
                    leading: Icon(kind.icon),
                    title: Text(kind.label),
                    subtitle: Text(kind.shortHint),
                    selected: kind == selected,
                    onTap: () => onPick(kind),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
