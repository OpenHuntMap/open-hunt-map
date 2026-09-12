import 'package:flutter/material.dart';

import '../tracks/track_math.dart';
import '../tracks/track_preview.dart';
import 'waypoint_store.dart';

/// What the card asks the map to do once it closes.
sealed class WaypointCardRequest {
  const WaypointCardRequest();
}

final class EditFromCard extends WaypointCardRequest {
  const EditFromCard(this.waypoint);

  final Waypoint waypoint;
}

final class FollowFromCard extends WaypointCardRequest {
  const FollowFromCard(this.track, {required this.reversed});

  final Waypoint track;
  final bool reversed;
}

/// Ask for Land Info at the spot that was tapped rather than about the track.
///
/// Exists because a track's line and markers are a wide target, so making a tap
/// on one open the track would otherwise take Land Info away from every strip of
/// ground the user has walked — which is the ground they are most likely to be
/// asking about.
final class LandInfoFromCard extends WaypointCardRequest {
  const LandInfoFromCard();
}

/// What one of the user's own waypoints or tracks says when tapped on the map.
///
/// A tap used to do nothing at all on a waypoint, and on a track it opened Land
/// Info as though the user had tapped bare ground. Everything they might want to
/// do to a track was five taps away in the list.
Future<WaypointCardRequest?> showWaypointCard(
  BuildContext context,
  Waypoint waypoint,
) => showModalBottomSheet<WaypointCardRequest>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(child: _WaypointCard(waypoint: waypoint)),
);

class _WaypointCard extends StatelessWidget {
  const _WaypointCard({required this.waypoint});

  final Waypoint waypoint;

  bool get _isTrack => waypoint.isTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(waypoint.icon.icon, color: waypoint.displayColour),
          title: Text(waypoint.name),
          // Where it is, or how far it goes. The icon's label used to lead this
          // line, back when it was a category and was the nearest thing to a
          // description; it is a picture now, and naming the picture would say
          // nothing the glyph beside it has not already said. What the waypoint
          // is, if the user said, is in the tags below.
          subtitle: Text(
            _isTrack
                ? describeTrack(waypoint.track)
                : '${waypoint.latitude.toStringAsFixed(5)}, '
                      '${waypoint.longitude.toStringAsFixed(5)}',
          ),
        ),
        // The look, shown rather than named, so the card is the same answer as
        // the line the user just tapped.
        if (_isTrack)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TrackPreview(
              colour: waypoint.displayColour,
              stroke: waypoint.stroke,
              marker: waypoint.marker,
            ),
          ),
        if (waypoint.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(waypoint.notes),
          ),
        if (waypoint.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              waypoint.tags.map((tag) => '#$tag').join(' '),
              style: theme.textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (_isTrack) ...[
                FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    FollowFromCard(waypoint, reversed: false),
                  ),
                  icon: const Icon(Icons.navigation_outlined),
                  label: const Text('Follow'),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    FollowFromCard(waypoint, reversed: true),
                  ),
                  icon: const Icon(Icons.u_turn_left),
                  label: const Text('Reverse'),
                ),
              ],
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.pop(context, EditFromCard(waypoint)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
              TextButton.icon(
                onPressed: () =>
                    Navigator.pop(context, const LandInfoFromCard()),
                icon: const Icon(Icons.travel_explore),
                label: const Text('Land info'),
              ),
            ],
          ),
        ),
        // Deleting stays in the list, where the undo and the whole-category
        // sweep already live. One tap from the map is the wrong distance for it.
      ],
    );
  }
}
