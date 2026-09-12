import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../waypoints/waypoint_store.dart';
import 'track_math.dart';

/// The bar shown while a track is being recorded.
///
/// Recording used to say nothing beyond a red button and a red line, so the one
/// question a recording user actually has — how far have I come — was the one
/// question the app would not answer. Laid out like [FollowBar] for the same
/// reason: one big number readable at arm's length, one quiet sentence under it.
class RecordingBar extends StatefulWidget {
  const RecordingBar({
    super.key,
    required this.points,
    required this.startedAt,
    required this.rejectedFixes,
    required this.onStop,
  });

  final List<TrackPoint> points;

  /// When recording began, rather than the first point's timestamp.
  ///
  /// Elapsed time has to keep climbing while the walker stands still. Derived
  /// from the points it would freeze, because a stationary phone produces fixes
  /// that are dropped as duplicates and never reach the list.
  final DateTime startedAt;

  final int rejectedFixes;
  final VoidCallback onStop;

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Local to this bar rather than driven from the map shell, so a clock that
    // has to move every second does not rebuild the map with it.
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onContainer = theme.colorScheme.onSurface;
    // Read through package:clock, which is the wall clock everywhere except
    // under a test, so a test can watch this number climb. Wall time rather
    // than a counter the timer increments, because timers are throttled while
    // the app is in the background and a walk spends most of its time there.
    final elapsed = clock.now().difference(widget.startedAt);

    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // The universal recording mark, in the error colour but not on an
                // error container: this is a mode to stay aware of, not a fault.
                Icon(
                  Icons.fiber_manual_record,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recording a track',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: onContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Stop and save track',
                  icon: const Icon(Icons.stop),
                  color: onContainer,
                  onPressed: widget.onStop,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        formatDistance(trackLengthMetres(widget.points)),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: onContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        formatDuration(elapsed),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onContainer.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _status(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: onContainer,
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

  /// The sentence under the number.
  ///
  /// The point count is the "this is working" signal, and the dropped fixes are
  /// said out loud while there is still time to act on them: under heavy canopy
  /// they are the difference between a gap you know about and one you find out
  /// about when you get home.
  ///
  /// The single-point case used to read "waiting for a second fix", which blamed
  /// the satellites for something the app was doing. Recording seeds a point
  /// immediately and the stream then only reports a move of five metres or more,
  /// so a stationary phone with a perfect lock sits at one point indefinitely —
  /// verified on a phone holding thirty satellites at nine metres. Saying it is
  /// waiting for a fix sends someone outside to look for sky they already have.
  String _status() {
    final dropped = widget.rejectedFixes;
    final poor = '$dropped poor ${dropped == 1 ? 'fix' : 'fixes'} dropped';
    return switch (widget.points.length) {
      // Dropped fixes come first here because at one point they are the whole
      // story: this is the reading that says the sky, not the walking, is the
      // problem.
      <= 1 when dropped > 0 => '$poor · waiting for one accurate enough',
      <= 1 => 'Ready · the line starts once you move',
      final points when dropped == 0 => '$points points',
      final points => '$points points · $poor',
    };
  }
}
