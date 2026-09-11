import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'track_style.dart';

/// A sample of a track's line, drawn the way the map draws it.
///
/// Worth painting rather than naming. "Dotted with double chevrons" is a
/// combination nobody can picture from the words, and without a preview the only
/// place the answer appears is the map itself — after the sheet has closed.
class TrackPreview extends StatelessWidget {
  const TrackPreview({
    super.key,
    required this.colour,
    required this.stroke,
    required this.marker,
  });

  final Color colour;
  final TrackStroke stroke;
  final TrackMarker marker;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    width: double.infinity,
    child: CustomPaint(
      painter: _TrackPreviewPainter(
        colour: colour,
        stroke: stroke,
        marker: marker,
      ),
    ),
  );
}

class _TrackPreviewPainter extends CustomPainter {
  _TrackPreviewPainter({
    required this.colour,
    required this.stroke,
    required this.marker,
  });

  final Color colour;
  final TrackStroke stroke;
  final TrackMarker marker;

  @override
  void paint(Canvas canvas, Size size) {
    final width = trackLineWidth * trackPreviewScale;
    final y = size.height / 2;
    final paint = Paint()
      ..color = colour
      ..strokeWidth = width
      ..strokeCap = stroke.cap == 'round' ? StrokeCap.round : StrokeCap.butt;

    final dash = stroke.dash;
    if (dash == null) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    } else {
      // Dash lengths are in line widths on the map, so they are here too. This
      // is the whole reason the preview can be trusted: the same numbers drive
      // both, rather than a hand-tuned imitation of each pattern.
      final on = dash[0] * width;
      final off = dash[1] * width;
      for (var x = 0.0; x < size.width; x += on + off) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + on, size.width), y),
          paint,
        );
      }
    }

    final icon = marker.icon;
    if (icon == null) return;
    // The map scales a 64 px box down to [trackMarkerSizeDp] and the glyph fills
    // 80% of that box; a Material icon at font size N has ink close to N, which
    // is what makes these two the same size.
    final fontSize = trackMarkerSizeDp * 0.8 * trackPreviewScale;

    TextPainter glyph(TextStyle style) => TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: style.copyWith(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: fontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Two passes, halo then fill, because that is what the map does. Skipping
    // the halo made this preview lie in the one case it matters: a marker
    // landing in a gap between dots has nothing behind it, so without the halo
    // it looked invisible here and read perfectly well on the map.
    final halo = glyph(
      TextStyle(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          // Doubled, because a stroke straddles the outline and the map's halo
          // width is the distance it reaches outward from it.
          ..strokeWidth = trackMarkerHaloWidth * trackPreviewScale * 2
          ..strokeJoin = StrokeJoin.round
          ..color = colour,
      ),
    );
    final fill = glyph(TextStyle(color: markerColourFor(colour)));

    final spacing = trackMarkerSpacing * trackPreviewScale;
    for (var x = spacing / 2; x < size.width; x += spacing) {
      final at = Offset(x - fill.width / 2, y - fill.height / 2);
      halo.paint(canvas, at);
      fill.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_TrackPreviewPainter old) =>
      old.colour != colour || old.stroke != stroke || old.marker != marker;
}
