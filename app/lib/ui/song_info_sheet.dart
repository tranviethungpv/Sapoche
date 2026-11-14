import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'collection_screen.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/motion.dart';

/// What is known about a song: who sings it, which album and year, how long it is, how many watched it.
void showSongInfo(BuildContext context, Track entry, {String? addedBy}) {
  final music = AppScope.of(context).music;
  showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: Motion.sheet(context),
    builder: (context) => _SongInfo(
      entry: entry,
      addedBy: addedBy,
      radio: music.radio(entry.videoId),
      views: entry.isLocal ? null : music.viewCount(entry),
    ),
  );
}

class _SongInfo extends StatelessWidget {
  const _SongInfo({
    required this.entry,
    required this.radio,
    required this.views,
    this.addedBy,
  });

  final Track entry;
  final String? addedBy;
  final Future<SongRadio> radio;

  /// How many watched it, for a song that is not on the phone.
  final Future<({int count, bool plays})?>? views;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: FutureBuilder<({int count, bool plays})?>(
        future: views,
        builder: (context, counted) => FutureBuilder<SongRadio>(
          future: radio,
          builder: (context, async) {
            // What YouTube Music adds arrives later; the sheet shows what the queue knows meanwhile
            final song = async.data?.songOf(entry.videoId);
            Widget row(String label, String? value, {VoidCallback? onTap}) {
              if (value == null || value.isEmpty) {
                return const SizedBox.shrink();
              }
              return InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text(
                          label,
                          style: theme.bodyMedium?.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          style: theme.bodyLarge?.copyWith(
                            color: onTap != null ? p.primary : p.text,
                          ),
                        ),
                      ),
                      if (onTap != null)
                        Icon(
                          Icons.chevron_right_rounded,
                          color: p.textTertiary,
                        ),
                    ],
                  ),
                ),
              );
            }

            final artistId = song?.artistId;
            // A song from a search comes without its length: YouTube Music's own page of the song has it, and for the
            // song that plays, so does the player. Where none says, the row is left out rather than say 0:00.
            final room = AppScope.roomOf(context);
            final length = entry.durMs > 0
                ? entry.durMs
                : (song?.durMs ?? 0) > 0
                ? song!.durMs
                : room.snapshot.current?.videoId == entry.videoId
                ? room.durationMs()
                : 0;
            // The count of the list that showed the song, when one did: it is the one number of the song
            final seen = AppScope.of(context).music.seenViews(entry.videoId);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Artwork(url: entry.thumb, size: 72, radius: 12),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.titleLarge,
                            ),
                            Text(
                              entry.artist,
                              style: theme.bodyMedium?.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  row(
                    S.infoArtist,
                    entry.artist,
                    onTap: artistId == null
                        ? null
                        : () {
                            Navigator.pop(context);
                            openArtist(context, artistId);
                          },
                  ),
                  row(
                    S.infoAlbum,
                    song?.album,
                    onTap: song?.albumId == null
                        ? null
                        : () {
                            Navigator.pop(context);
                            openCollection(
                              context,
                              id: song!.albumId!,
                              title: song.album,
                              thumb: song.thumb,
                            );
                          },
                  ),
                  row(S.infoYear, song?.year),
                  row(S.infoLength, length > 0 ? formatDuration(length) : null),
                  // The count of the player, said in the language of the app; what YouTube Music said of the video until it comes
                  row(
                    (seen != null
                            ? seen.endsWith(S.playCount(''))
                            : counted.data?.plays ?? song?.isSong ?? false)
                        ? S.infoPlays
                        : S.infoReach,
                    seen != null
                        ? shortViews(seen)
                        : counted.data == null
                        ? song?.stats
                        : formatCount(counted.data!.count),
                  ),
                  row(
                    S.infoKind,
                    song == null
                        ? null
                        : (song.isSong ? S.kindSong : S.kindVideo),
                  ),
                  row(S.addedByLabel, addedBy),
                  if (async.connectionState != ConnectionState.done)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
