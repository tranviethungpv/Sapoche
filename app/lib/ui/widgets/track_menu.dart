import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../scope.dart';
import '../song_info_sheet.dart';
import 'download_actions.dart';
import 'menu_lines.dart';
import 'not_interested.dart';
import 'playlist_picker.dart';
import 'queue_actions.dart';
import 'track_links.dart';
import 'track_tile.dart';

/// The "…" of a song, the same wherever the song is shown (a search, a playlist, an artist, the library, the player), so
/// that what can be done to a song does not depend on the page it was found on. A phone gets the sheet, a wide window the
/// small menu.
///
/// Where the song is the one playing, [onAdd] and [onPlayNext] are left out and so are the two lines they would serve.
/// [addedBy] is who put it on the queue, for the sheet of the song's info.
class TrackMenu extends StatelessWidget {
  const TrackMenu({
    super.key,
    required this.track,
    this.onAdd,
    this.onPlayNext,
    this.addedBy,
  });

  final Track track;
  final VoidCallback? onAdd;
  final VoidCallback? onPlayNext;
  final String? addedBy;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final room = AppScope.roomOf(context);
    // A file on this phone has no YouTube artist or album, is not downloaded, has no link and is not to be blocked
    final online = !track.isLocal;
    List<MenuLine> lines() => [
      if (onPlayNext != null)
        MenuLine('next', Icons.playlist_play_rounded, S.playNext),
      if (onAdd != null)
        MenuLine('end', Icons.queue_music_rounded, S.addToQueue),
      MenuLine(
        'like',
        library.isLikedSong(track)
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        library.isLikedSong(track) ? S.unlike : S.like,
      ),
      MenuLine('playlist', Icons.playlist_add_rounded, S.addToPlaylist),
      // A browser downloads nothing
      if (online && !kIsWeb)
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
      if (online)
        MenuLine('artist', Icons.person_outline_rounded, S.goToArtist),
      if (online) MenuLine('album', Icons.album_outlined, S.goToAlbum),
      if (online) MenuLine('share', Icons.ios_share_rounded, S.shareSong),
      // Only where the room has a chat to send it to
      if (canSendToChat(room, track))
        MenuLine('chat', Icons.chat_bubble_outline_rounded, S.songSendToChat),
      MenuLine('info', Icons.info_outline_rounded, S.songInfo),
      if (online)
        MenuLine('blocked', Icons.block_rounded, S.notInterested, apart: true),
    ];
    return SongMenuButton(
      // The row this is in opens it from a right click
      menuKey: RowMenuKey.maybeOf(context),
      track: track,
      lines: lines,
      onSelected: (value) => switch (value) {
        'next' => onPlayNext?.call(),
        'end' => onAdd?.call(),
        'like' => library.toggleLike(track),
        'playlist' => showAddToPlaylist(context, [track]),
        'download' => startDownload(context, [track]),
        'undownload' => library.removeDownload(track.videoId),
        'artist' => openArtistOf(context, track),
        'album' => openAlbumOf(context, track),
        'share' => room.shareSong(track),
        'chat' => sendTrackToChat(context, track),
        'info' => showSongInfo(context, track, addedBy: addedBy),
        'blocked' => showNotInterested(context, track),
        _ => null,
      },
    );
  }
}
