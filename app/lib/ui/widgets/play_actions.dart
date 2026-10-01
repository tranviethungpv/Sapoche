import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../scope.dart';
import 'queue_actions.dart';

/// What a touch on a song does. Outside a room the song starts in place of the queue, as YouTube Music does, and
/// the queue fills with songs like it; in a room the queue belongs to everybody, so it is put on the queue instead.
void playNow(BuildContext context, Track track) {
  HapticFeedback.selectionClick();
  final room = AppScope.roomOf(context);
  if (room.snapshot.inRoom) {
    queueTrack(context, track);
    return;
  }
  room.playSong(track);
}

/// A touch on song [index] of [tracks] (a playlist, a search for a playlist): outside a room it plays from there
/// to the end of the list, in a room the song is queued.
void playFrom(BuildContext context, List<Track> tracks, int index) {
  if (AppScope.roomOf(context).snapshot.inRoom) {
    playNow(context, tracks[index]);
    return;
  }
  HapticFeedback.selectionClick();
  AppScope.roomOf(context).playTracks(tracks.sublist(index));
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
      ..showSnackBar(SnackBar(content: Text(S.mixFailed)));
  }
  await scope.room.playTracks(songs);
}
