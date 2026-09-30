import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import 'track_menu.dart';

/// The buttons at the end of a song row that can be queued: a plus that turns into a tick once the song is in
/// the queue, and the "more" menu.
class AddActions extends StatelessWidget {
  const AddActions({
    super.key,
    required this.track,
    required this.added,
    required this.onAdd,
    required this.onPlayNext,
  });

  final Track track;
  final bool added;
  final VoidCallback onAdd;
  final VoidCallback onPlayNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final room = AppScope.roomOf(context);
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) => _row(p, added || room.snapshot.isQueued(track)),
    );
  }

  Widget _row(Palette p, bool added) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: added
              ? Icon(
                  Icons.check_circle_rounded,
                  key: const ValueKey('done'),
                  color: p.success,
                  size: 30,
                )
              : IconButton.filledTonal(
                  key: const ValueKey('add'),
                  onPressed: onAdd,
                  style: IconButton.styleFrom(
                    backgroundColor: p.primaryContainer,
                    foregroundColor: p.onPrimaryContainer,
                    fixedSize: const Size(36, 36),
                  ),
                  iconSize: 20,
                  icon: const Icon(Icons.add_rounded),
                ),
        ),
        TrackMenu(track: track, onAdd: onAdd, onPlayNext: onPlayNext),
      ],
    );
  }
}

/// Puts [track] on the queue (or next) and says so, unless it is waiting there already.
Future<void> queueTrack(
  BuildContext context,
  Track track, {
  bool playNext = false,
}) async {
  HapticFeedback.selectionClick();
  final room = AppScope.roomOf(context);
  final messenger = ScaffoldMessenger.of(context);
  final queued = room.snapshot.isQueued(track);
  if (!queued) await room.add(track, playNext: playNext);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          queued
              ? S.alreadyInQueue
              : playNext
              ? S.willPlayNext
              : S.addedToQueue,
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
}
