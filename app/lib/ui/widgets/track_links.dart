import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../strings.dart';
import '../artist_page.dart';
import '../collection_screen.dart' show openCollection;
import '../scope.dart';

/// Opens the page of the artist of [song], which YouTube Music is asked for unless the song already knows it; says so
/// when it cannot be found.
Future<void> openArtistOf(BuildContext context, Track song) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  String? id = song is MusicTrack ? song.artistId : null;
  if (id == null) {
    try {
      final radio = await AppScope.of(context).music.radio(song.videoId);
      id = radio.songOf(song.videoId)?.artistId;
    } on Object {
      // Said below
    }
  }
  if (id == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.musicFailed)));
    return;
  }
  if (navigator.mounted) await openArtist(navigator.context, id);
}

/// Opens the page of the album [song] is on, which YouTube Music is asked for unless the song already knows it; says so
/// when it is on none (a single video, a song it does not know the album of).
Future<void> openAlbumOf(BuildContext context, Track song) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  MusicTrack? found = song is MusicTrack && song.albumId != null ? song : null;
  if (found == null) {
    try {
      found = (await AppScope.of(context).music.radio(song.videoId))
          .songOf(song.videoId);
    } on Object {
      // Said below
    }
  }
  final id = found?.albumId;
  if (id == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.noAlbum)));
    return;
  }
  if (navigator.mounted) {
    await openCollection(
      navigator.context,
      id: id,
      title: found?.album ?? song.title,
      thumb: song.thumb,
    );
  }
}
