import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../scope.dart';
import 'download_actions.dart';
import 'menu_lines.dart';
import 'not_interested.dart';
import 'playlist_picker.dart';
import 'queue_actions.dart';
import 'track_tile.dart';

/// The "more" menu of a song row: play it next, queue it, like it.
class TrackMenu extends StatelessWidget {
  const TrackMenu({
    super.key,
    required this.track,
    required this.onAdd,
    required this.onPlayNext,
  });

  final Track track;
  final VoidCallback onAdd;
  final VoidCallback onPlayNext;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    List<MenuLine> lines() => [
      MenuLine('next', Icons.playlist_play_rounded, S.playNext),
      MenuLine('end', Icons.queue_music_rounded, S.addToQueue),
      MenuLine('playlist', Icons.playlist_add_rounded, S.addToPlaylist),
      // Only where the room has a chat to send it to
      if (canSendToChat(AppScope.roomOf(context), track))
        MenuLine('chat', Icons.chat_bubble_outline_rounded, S.songSendToChat),
      // A file on this phone is not downloaded, and has no YouTube artist to be tired of; a browser downloads nothing
      if (!track.isLocal && !kIsWeb)
        ...switch (library.downloadState(track.videoId)) {
          DownloadState.done => [
            MenuLine(
              'undownload',
              Icons.download_done_rounded,
              S.removeDownload,
            ),
          ],
          DownloadState.queued || DownloadState.waiting => [
            MenuLine(
              'none',
              Icons.downloading_rounded,
              S.downloading,
              enabled: false,
            ),
          ],
          _ => [MenuLine('download', Icons.download_rounded, S.download)],
        },
      MenuLine(
        'like',
        library.isLikedSong(track)
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        library.isLikedSong(track) ? S.unlike : S.like,
      ),
      if (!track.isLocal)
        MenuLine('blocked', Icons.block_rounded, S.notInterested, apart: true),
    ];
    return SongMenuButton(
      // The row this is in opens it from a right click
      menuKey: RowMenuKey.maybeOf(context),
      track: track,
      lines: lines,
      onSelected: (value) => switch (value) {
        'next' => onPlayNext(),
        'like' => library.toggleLike(track),
        'playlist' => showAddToPlaylist(context, [track]),
        'chat' => sendTrackToChat(context, track),
        'download' => startDownload(context, [track]),
        'undownload' => library.removeDownload(track.videoId),
        'blocked' => showNotInterested(context, track),
        _ => onAdd(),
      },
    );
  }
}
