import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/song_key.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';

/// Lets the person say they do not want a song, or its artist, offered again, and keeps it from then on.
Future<void> showNotInterested(BuildContext context, Track track) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final artistOnly = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context).textTheme;
      final artist = displayArtist(track.artist);
      return SafeArea(
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
              onTap: () => Navigator.pop(context, false),
            ),
            if (artist.isNotEmpty)
              ListTile(
                key: const ValueKey('not-interested-artist'),
                leading: Icon(
                  Icons.person_off_outlined,
                  color: context.palette.primary,
                ),
                title: Text(S.notInterestedArtist(artist)),
                onTap: () => Navigator.pop(context, true),
              ),
          ],
        ),
      );
    },
  );
  if (artistOnly == null) return;
  await library.block(track, artistOnly: artistOnly);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(S.wontSuggest)));
}
