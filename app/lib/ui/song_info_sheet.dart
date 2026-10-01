import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'scope.dart';
import 'widgets/artwork.dart';

/// What is known about a song: who sings it, which album and year, how long it is, how many watched it.
void showSongInfo(BuildContext context, QueueEntry entry, {String? addedBy}) {
  final music = AppScope.of(context).music;
  showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: context.palette.surface,
    builder: (context) => _SongInfo(
      entry: entry,
      addedBy: addedBy,
      radio: music.radio(entry.videoId),
    ),
  );
}

class _SongInfo extends StatelessWidget {
  const _SongInfo({required this.entry, required this.radio, this.addedBy});

  final QueueEntry entry;
  final String? addedBy;
  final Future<SongRadio> radio;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: FutureBuilder<SongRadio>(
        future: radio,
        builder: (context, async) {
          // What YouTube Music adds arrives later; the sheet shows what the queue knows meanwhile
          final song = async.data?.songOf(entry.videoId);
          Widget row(String label, String? value, {VoidCallback? onTap}) {
            if (value == null || value.isEmpty) return const SizedBox.shrink();
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
                      Icon(Icons.chevron_right_rounded, color: p.textTertiary),
                  ],
                ),
              ),
            );
          }

          final artistId = song?.artistId;
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
                row(S.infoAlbum, song?.album),
                row(S.infoYear, song?.year),
                row(S.infoLength, formatDuration(entry.durMs)),
                row(S.infoReach, song?.stats),
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
    );
  }
}
