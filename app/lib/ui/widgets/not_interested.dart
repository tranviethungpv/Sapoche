import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/song_key.dart';
import '../../strings.dart';
import 'motion.dart';
import 'sheet_tile.dart';
import '../scope.dart';

enum _Choice { blockSong, blockArtist, notCounted, suggestLess }

/// Lets the person say they do not want a song, or its artist, offered again, or that the song is not to count in their
/// taste or its artist is to be suggested less, and keeps it from then on.
Future<void> showNotInterested(BuildContext context, Track track) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<_Choice>(
    context: context,
    useRootNavigator: true,
    sheetAnimationStyle: Motion.sheet(context),
    builder: (context) {
      final theme = Theme.of(context).textTheme;
      final artist = displayArtist(track.artist);
      // The rows are made as those of the room's settings are (`SheetTile`), in the same margins
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(S.notInterested, style: theme.headlineSmall),
              const SizedBox(height: 8),
              SheetTile(
                key: const ValueKey('not-interested-song'),
                icon: Icons.music_off_outlined,
                title: S.notInterestedSong,
                help: track.title,
                onTap: () => Navigator.pop(context, _Choice.blockSong),
              ),
              if (artist.isNotEmpty)
                SheetTile(
                  key: const ValueKey('not-interested-artist'),
                  icon: Icons.person_off_outlined,
                  title: S.notInterestedArtist(artist),
                  onTap: () => Navigator.pop(context, _Choice.blockArtist),
                ),
              SheetTile(
                key: const ValueKey('not-counted-song'),
                icon: Icons.visibility_off_outlined,
                title: S.notCountedSong,
                onTap: () => Navigator.pop(context, _Choice.notCounted),
              ),
              if (artist.isNotEmpty && !track.isLocal)
                SheetTile(
                  key: const ValueKey('suggest-less-artist'),
                  icon: Icons.trending_down_rounded,
                  title: S.suggestLessArtist(artist),
                  onTap: () => Navigator.pop(context, _Choice.suggestLess),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (choice == null) return;
  switch (choice) {
    case _Choice.blockSong || _Choice.blockArtist:
      await library.block(track, artistOnly: choice == _Choice.blockArtist);
    case _Choice.notCounted:
      await library.setTasteMark(
        TasteMarks.quietSong,
        track.videoId,
        track.title,
        on: true,
      );
    case _Choice.suggestLess:
      await library.setTasteMark(
        TasteMarks.quietArtist,
        mainArtist(track.artist),
        displayArtist(track.artist),
        on: true,
      );
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(switch (choice) {
          _Choice.blockSong || _Choice.blockArtist => S.wontSuggest,
          _Choice.notCounted => S.wontCount,
          _Choice.suggestLess => S.willSuggestLess,
        }),
      ),
    );
}
