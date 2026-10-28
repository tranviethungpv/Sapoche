import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import 'avatars.dart';
import 'delete_background.dart';
import 'track_tile.dart';

/// The songs autoplay lined up in a room. They play after the queue the members made and are not part of it, which the
/// note says; a touch plays one now and a swipe takes it off.
class QueuedAutoplay extends StatelessWidget {
  const QueuedAutoplay({
    super.key,
    required this.controller,
    required this.entries,
  });

  final RoomController controller;
  final List<QueueEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(
            S.roomAutoplayQueued,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.palette.textSecondary,
            ),
          ),
        ),
        for (final entry in entries)
          Dismissible(
            key: ValueKey('autoplay-${entry.id}'),
            direction: DismissDirection.endToStart,
            background: const DeleteBackground(),
            onDismissed: (_) {
              HapticFeedback.lightImpact();
              controller.remove(entry);
            },
            child: TrackTile(
              track: entry,
              badge: const AutoplayBadge(),
              onTap: () => controller.jump(entry),
            ),
          ),
      ],
    );
  }
}
