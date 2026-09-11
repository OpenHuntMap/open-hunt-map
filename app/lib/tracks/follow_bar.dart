import 'package:flutter/material.dart';

import '../waypoints/waypoint_store.dart';
import 'track_follow.dart';
import 'track_math.dart';

/// The bar shown while following a track.
///
/// Written to be read at arm's length in bad light with one hand holding
/// something else, so there is one big number and one sentence under it. The
/// distance remaining is the big one because it is the question being asked; how
/// far you have come is on the same row but quieter.
class FollowBar extends StatelessWidget {
  const FollowBar({
    super.key,
    required this.track,
    required this.reversed,
    required this.guidance,
    required this.onReverse,
    required this.onStop,
  });

  final Waypoint track;
  final bool reversed;

  /// Null until the first fix arrives, which is a state the bar has to show
  /// rather than fill with a plausible zero.
  final FollowGuidance? guidance;

  final VoidCallback onReverse;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offRoute = guidance?.offRoute ?? false;
    final arrived = guidance?.arrived ?? false;
    final container = switch ((offRoute, arrived)) {
      (true, _) => theme.colorScheme.errorContainer,
      (_, true) => theme.colorScheme.tertiaryContainer,
      _ => theme.colorScheme.surfaceContainerHigh,
    };
    final onContainer = switch ((offRoute, arrived)) {
      (true, _) => theme.colorScheme.onErrorContainer,
      (_, true) => theme.colorScheme.onTertiaryContainer,
      _ => theme.colorScheme.onSurface,
    };

    return Card(
      color: container,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(track.category.icon, color: track.displayColour, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: onContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Named rather than shown only as a swap arrow, because
                // "following this in reverse" is the fact most worth being sure
                // of and an icon alone does not say which state you are in.
                Text(
                  reversed ? 'Reverse' : 'Forward',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: onContainer.withValues(alpha: 0.75),
                  ),
                ),
                IconButton(
                  tooltip: reversed
                      ? 'Follow the other way'
                      : 'Follow in reverse',
                  icon: const Icon(Icons.swap_horiz),
                  color: onContainer,
                  onPressed: onReverse,
                ),
                IconButton(
                  tooltip: 'Stop following',
                  icon: const Icon(Icons.close),
                  color: onContainer,
                  onPressed: onStop,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: _body(theme, onContainer),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme, Color onContainer) {
    final guidance = this.guidance;
    if (guidance == null) {
      return Text(
        'Waiting for a position fix…',
        style: theme.textTheme.bodyMedium?.copyWith(color: onContainer),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              guidance.arrived
                  ? 'At the end'
                  : '${formatDistance(guidance.remainingMetres)} to go',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: onContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${formatDistance(guidance.travelledMetres)} done',
              style: theme.textTheme.bodySmall?.copyWith(
                color: onContainer.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          _status(guidance),
          style: theme.textTheme.bodyMedium?.copyWith(color: onContainer),
        ),
      ],
    );
  }

  /// The sentence under the number.
  ///
  /// Off route comes first and takes the whole line, because when someone is off
  /// the track the direction the track happens to run next is not what they need
  /// to know. On route it names the next heading in degrees and as a compass
  /// point: the degrees are what a compass gets set to and the name is what makes
  /// the number checkable at a glance.
  String _status(FollowGuidance guidance) {
    if (guidance.offRoute) {
      final bearing = guidance.bearingToTrack;
      final away = formatDistance(guidance.offTrackMetres);
      return bearing == null
          ? '$away off the track'
          : '$away off the track — head ${bearing.round()}° '
                '${compassPoint(bearing)} to rejoin it';
    }
    if (guidance.arrived) return 'You have reached the end of this track.';
    final heading = guidance.headingAlong;
    if (heading == null) return 'On the track.';
    return 'On the track · continues ${heading.round()}° '
        '${compassPoint(heading)}';
  }
}
