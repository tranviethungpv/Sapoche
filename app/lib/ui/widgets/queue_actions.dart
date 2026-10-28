import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../scope.dart';

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
  final undo = queued ? null : undoAddAction(room, track);
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
        action: undo,
        // Long enough to reach the way back
        duration: Duration(milliseconds: undo == null ? 1400 : 4000),
      ),
    );
}

/// The way back from putting [track] on the queue, asked before it is put there: only when it will wait behind a song
/// (on a queue with nothing playing it starts at once, and the way back from that is pause), and only for whoever may
/// take songs off: not a guest of a room where guests may only add songs.
SnackBarAction? undoAddAction(RoomController room, Track track) {
  final snapshot = room.snapshot;
  if (!snapshot.canControl ||
      snapshot.current == null ||
      snapshot.phase == 'idle') {
    return null;
  }
  return SnackBarAction(label: S.undo, onPressed: () => room.undoAdd(track));
}

/// Puts [tracks] on the queue (or next) and says how many went on: the ones already waiting there are left out.
Future<void> queueTracks(
  BuildContext context,
  List<Track> tracks, {
  bool playNext = false,
}) async {
  HapticFeedback.selectionClick();
  final room = AppScope.roomOf(context);
  final messenger = ScaffoldMessenger.of(context);
  final fresh = room.snapshot.fresh(tracks);
  // What the queue has room for; a full one is told by the room itself
  final space =
      queueMax(inRoom: room.snapshot.inRoom) - room.snapshot.queue.length;
  if (fresh.isNotEmpty) await room.addMany(fresh, playNext: playNext);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          fresh.isEmpty
              ? S.alreadyInQueue
              : fresh.length > space && space > 0
              ? S.addedSome(space, fresh.length)
              : fresh.length < tracks.length
              ? S.addedSkipped(fresh.length, tracks.length - fresh.length)
              : S.playlistAdded,
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
}
