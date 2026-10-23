import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/song_key.dart';
import '../../data/spread_shuffle.dart';
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

/// Plays [tracks], a mix that was made for the person: outside a room it takes the place of the queue, in a room
/// it is put on the queue.
Future<void> playMix(BuildContext context, List<Track> tracks) async {
  if (AppScope.roomOf(context).snapshot.inRoom) {
    return queueTracks(context, tracks);
  }
  HapticFeedback.selectionClick();
  await AppScope.roomOf(context).playTracks(tracks);
}

/// Plays the songs of [playlists] (the playlists of a folder) as one list: the playlists one after the other, or with
/// [shuffle] mixed together, each spread evenly along the whole. Outside a room it takes the place of the queue, in a
/// room it is put on the queue. Says when the queue could not hold them all.
Future<void> playPlaylists(
  BuildContext context,
  List<SavedPlaylist> playlists, {
  required bool shuffle,
}) async {
  HapticFeedback.selectionClick();
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  final lists = await scope.library.songsOfPlaylists([
    for (final p in playlists) p.id,
  ]);
  final songs = uniqueSongs(
    shuffle ? spreadShuffle(lists) : [for (final list in lists) ...list],
  );
  if (songs.isEmpty) return say(S.folderNoSongs);
  if (scope.room.snapshot.inRoom) {
    if (context.mounted) await queueTracks(context, songs);
    return;
  }
  final kept = await scope.room.playTracks(songs);
  if (kept < songs.length) say(S.playingSome(kept, songs.length));
}
