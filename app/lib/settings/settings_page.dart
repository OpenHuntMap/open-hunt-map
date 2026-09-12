import 'package:flutter/material.dart';

import '../waypoints/waypoint_colour.dart';
import '../waypoints/waypoint_icon.dart';
import 'display_settings.dart';
import 'marker_style.dart';

/// The app's settings, which are only the ones that exist.
///
/// Deliberately one screen with one section. There is no appetite here for a
/// list of plausible-looking switches: everything on this page changes
/// something the user can see on the map the moment they go back to it.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.settings});

  final DisplaySettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text('Waypoints on the map', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'How saved waypoints are drawn. Nothing here changes a '
              'waypoint — only how it looks.',
              style: TextStyle(height: 1.35),
            ),
            const SizedBox(height: 14),
            _Preview(
              style: settings.markerStyle,
              size: settings.markerSize,
            ),
            _label(theme, 'Marker style'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final style in WaypointMarkerStyle.values)
                  ChoiceChip(
                    label: Text(style.label),
                    selected: settings.markerStyle == style,
                    onSelected: (_) => settings.setMarkerStyle(style),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              settings.markerStyle.blurb,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
            _label(theme, 'Marker size'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final size in WaypointMarkerSize.values)
                  ChoiceChip(
                    label: Text(size.label),
                    selected: settings.markerSize == size,
                    onSelected: (_) => settings.setMarkerSize(size),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Each of these is something the user would otherwise have to
            // discover by being surprised on a hillside.
            for (final note in const [
              'Size also scales the direction arrows along a track, so '
                  'waypoints and tracks stay in proportion.',
              'Markers are never dropped to avoid overlap, so a larger size '
                  'crowds a busy area rather than hiding the one you are '
                  'looking for.',
              'A pin’s point sits on the coordinate and a bare icon is '
                  'centred on it. Switching between them does not move a '
                  'waypoint.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('·  '),
                    Expanded(
                      child: Text(
                        note,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                      ),
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
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Text(text, style: theme.textTheme.labelLarge),
      );
}

/// What the map will draw, at the chosen style and size.
///
/// Laid out from the same constants and the same offsets the map layers use, so
/// the preview cannot start showing an anchor the map does not honour. It is
/// still an approximation in one respect: these are Flutter `Icon`s drawn from
/// the Material font, and the map draws generated images whose ink fills a
/// slightly different fraction of its box, so the pin reads a few percent
/// larger here than on the map.
class _Preview extends StatelessWidget {
  const _Preview({required this.style, required this.size});

  final WaypointMarkerStyle style;
  final WaypointMarkerSize size;

  /// Tall enough for the largest pin, and fixed, so that changing the size step
  /// is a change in the marker against an unmoving frame rather than the whole
  /// page growing.
  static const _height = 96.0;

  /// Where the coordinate is. Low in the frame, because a marker occupies the
  /// space above the spot it marks and almost none below it.
  static const _ground = 74.0;

  /// Two dark colours and one light one, so the pin's light-on-dark and
  /// dark-on-light inks are both on screen rather than one of them being a
  /// surprise the first time a yellow waypoint is drawn.
  static const List<(WaypointIcon, WaypointColour?)> _samples = [
    (WaypointIcon.stand, null),
    (WaypointIcon.water, null),
    (WaypointIcon.hazard, WaypointColour.yellow),
  ];

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: _height,
          child: ColoredBox(
            // Stands in for ground. A mid green-grey is the case that actually
            // matters: it is the one background where neither a white nor a
            // dark glyph is comfortable, so a marker that reads here reads.
            color: const Color(0xFF6E7A5E),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: _ground,
                  height: 1,
                  child: const ColoredBox(color: Color(0x55FFFFFF)),
                ),
                Positioned.fill(
                  child: Row(
                    children: [
                      for (final (icon, colour) in _samples)
                        Expanded(
                          child: _PreviewMarker(
                            style: style,
                            size: size,
                            icon: icon,
                            colour: colour?.value ?? icon.colour,
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

class _PreviewMarker extends StatelessWidget {
  const _PreviewMarker({
    required this.style,
    required this.size,
    required this.icon,
    required this.colour,
  });

  final WaypointMarkerStyle style;
  final WaypointMarkerSize size;
  final WaypointIcon icon;
  final Color colour;

  /// A MapLibre `icon-offset`, in the source image's pixels, as logical pixels
  /// on screen. The same conversion the layer's `icon-size` performs.
  static double _dp(double sourcePx, double canvasDp) =>
      sourcePx * canvasDp / sdfCanvasPx;

  @override
  Widget build(BuildContext context) {
    final pinDp = pinCanvasDp(size);
    final glyphDp = glyphCanvasDp(size);
    final glyphDy = _dp(glyphImageOffset(style)[1], glyphDp);
    final inPin = style == WaypointMarkerStyle.pin;
    return Stack(
      children: [
        _at(
          0,
          dotRadiusDp(size) * 2 + dotStrokeDp(size) * 2,
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colour,
              border: Border.all(color: Colors.white, width: dotStrokeDp(size)),
            ),
          ),
        ),
        if (inPin) ...[
          _at(
            _dp(pinImageOffset[1], pinDp),
            pinDp,
            Icon(Icons.place, size: pinDp, color: colour),
          ),
          // Material's pin has a counter punched out of its head, and the
          // generated image has it filled. Filling it here too is what keeps
          // the preview from showing a hole the map does not draw.
          _at(
            glyphDy,
            glyphDp,
            Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
            ),
          ),
        ],
        _at(
          glyphDy,
          glyphDp,
          Icon(
            icon.icon,
            size: glyphDp,
            color: inPin ? pinGlyphColour(colour) : colour,
          ),
        ),
      ],
    );
  }

  /// Places [child] in a [box]-sized square whose centre is [dy] above or below
  /// the coordinate, which is where every MapLibre offset here is measured
  /// from.
  Widget _at(double dy, double box, Widget child) => Positioned(
        left: 0,
        right: 0,
        top: _Preview._ground + dy - box / 2,
        height: box,
        child: Center(
          child: SizedBox.square(dimension: box, child: child),
        ),
      );
}
