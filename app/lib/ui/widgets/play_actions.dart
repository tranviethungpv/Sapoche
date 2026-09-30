import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../scope.dart';
import 'add_actions.dart';

/// Plays [track] now. Outside a room that starts it in place of the queue, as YouTube Music does, and autoplay
/// carries on with songs like it; in a room the queue belongs to everybody, so it is put on the queue instead.
void playNow(BuildContext context, Track track) {
  HapticFeedback.selectionClick();
  final room = AppScope.roomOf(context);
  if (room.snapshot.inRoom) {
    queueTrack(context, track);
    return;
  }
  room.playTracks([track]);
}

/// Starts a mix: the radio of [seed], the song itself first. Without a network it plays the song alone.
Future<void> startMix(BuildContext context, Track seed) async {
  HapticFeedback.selectionClick();
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  var songs = <Track>[seed];
  try {
    final radio = await scope.music.radio(seed.videoId);
    if (radio.tracks.isNotEmpty) songs = radio.tracks.take(25).toList();
  } on Object {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(S.mixFailed)));
  }
  await scope.room.playTracks(songs);
}
