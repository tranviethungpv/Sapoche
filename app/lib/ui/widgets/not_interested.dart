import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/song_key.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
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
    builder: (context) {
      final theme = Theme.of(context).textTheme;
      final artist = displayArtist(track.artist);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(S.notInterested, style: theme.titleLarge),
              ),
              ListTile(
                key: const ValueKey('not-interested-song'),
                leading: Icon(
                  Icons.music_off_outlined,
                  color: context.palette.primary,
                ),
                title: Text(S.notInterestedSong),
                subtitle: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, _Choice.blockSong),
              ),
              if (artist.isNotEmpty)
                ListTile(
                  key: const ValueKey('not-interested-artist'),
                  leading: Icon(
                    Icons.person_off_outlined,
                    color: context.palette.primary,
                  ),
                  title: Text(S.notInterestedArtist(artist)),
                  onTap: () => Navigator.pop(context, _Choice.blockArtist),
                ),
              ListTile(
                key: const ValueKey('not-counted-song'),
                leading: Icon(
                  Icons.visibility_off_outlined,
                  color: context.palette.primary,
                ),
                title: Text(S.notCountedSong),
                onTap: () => Navigator.pop(context, _Choice.notCounted),
              ),
              if (artist.isNotEmpty && !track.isLocal)
                ListTile(
                  key: const ValueKey('suggest-less-artist'),
                  leading: Icon(
                    Icons.trending_down_rounded,
                    color: context.palette.primary,
                  ),
                  title: Text(S.suggestLessArtist(artist)),
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
