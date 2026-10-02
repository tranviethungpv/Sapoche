import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
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
  if (fresh.isNotEmpty) await room.addMany(fresh, playNext: playNext);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          fresh.isEmpty
              ? S.alreadyInQueue
              : fresh.length < tracks.length
              ? S.addedSkipped(fresh.length, tracks.length - fresh.length)
              : S.playlistAdded,
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
}
