import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import 'download_actions.dart';
import 'playlist_picker.dart';

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
    final p = context.palette;
    final library = AppScope.of(context).library;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz_rounded, color: p.textSecondary),
      color: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF2B1F25),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) => switch (value) {
        'next' => onPlayNext(),
        'like' => library.toggleLike(track),
        'playlist' => showAddToPlaylist(context, [track]),
        'download' => startDownload(context, [track]),
        'undownload' => library.removeDownload(track.videoId),
        _ => onAdd(),
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'next', child: Text(S.playNext)),
        const PopupMenuItem(value: 'end', child: Text(S.addToQueue)),
        const PopupMenuItem(value: 'playlist', child: Text(S.addToPlaylist)),
        ...switch (library.downloadState(track.videoId)) {
          DownloadState.done => const [
            PopupMenuItem(value: 'undownload', child: Text(S.removeDownload)),
          ],
          DownloadState.queued || DownloadState.waiting => const [
            PopupMenuItem(
              enabled: false,
              value: 'none',
              child: Text(S.downloading),
            ),
          ],
          _ => const [
            PopupMenuItem(value: 'download', child: Text(S.download)),
          ],
        },
        PopupMenuItem(
          value: 'like',
          child: Text(library.isLiked(track.videoId) ? S.unlike : S.like),
        ),
      ],
    );
  }
}
