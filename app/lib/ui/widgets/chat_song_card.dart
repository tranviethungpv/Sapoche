import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/chat_extra.dart';
import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../data/song_key.dart';
import '../../format.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../chat_look.dart';
import '../scope.dart';
import '../song_info_sheet.dart';
import 'artwork.dart';
import 'cached_cover.dart';
import 'equalizer.dart';

/// A song shared in the chat, drawn as a card instead of a bubble: its cover blurred behind it, the song, and the ways to
/// play it, queue it or like it. Over the cover goes a dark veil, so that the white words on it can be read whatever the
/// cover is (a contrast of 4.5 to 1 against a white one).
class ChatSongCard extends StatelessWidget {
  const ChatSongCard({super.key, required this.controller, required this.song});

  /// How much of the width of the screen the card takes, as the pictures of the chat do.
  static const widthFactor = 0.72;

  /// The veil over the cover and the colour of the chat: 0.58 of black leaves a white cover at about 0.15 of luminance.
  static const _veil = 0.58;

  final RoomController controller;
  final SongExtra song;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final look = ChatLookScope.of(context);
    return SizedBox(
      width: MediaQuery.sizeOf(context).width * widthFactor,
      child: ClipRRect(
        key: const ValueKey('song-card'),
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: _Backdrop(url: song.art, tint: look?.from ?? p.primary),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    key: const ValueKey('song-card-body'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showSongInfo(context, _entry),
                    child: _Heading(song: song),
                  ),
                  const SizedBox(height: 10),
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => _Actions(controller: controller, song: song),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The song as the sheet about a song takes it; nobody put it on the queue.
  QueueEntry get _entry => QueueEntry(
    id: '',
    videoId: song.videoId,
    title: song.title,
    artist: song.artist,
    durMs: song.durMs,
    addedBy: '',
    thumb: song.art,
  );
}

/// The cover enlarged and blurred, the colour of the chat over it, and the veil that makes white words readable.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.tint});

  final String? url;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: tint),
          if (url != null)
            ClipRect(
              child: Transform.scale(
                scale: 1.6,
                child: ImageFiltered(
                  imageFilter: _blur,
                  // A few dozen pixels are all a blur keeps of a cover
                  child: Image(
                    image: ResizeImage(CachedCover(url), width: 48, height: 48, allowUpscaling: false),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ColoredBox(color: tint.withValues(alpha: 0.35)),
          ColoredBox(color: Colors.black.withValues(alpha: ChatSongCard._veil)),
        ],
      ),
    );
  }

  static final _blur = ImageFilter.blur(sigmaX: 12, sigmaY: 12, tileMode: TileMode.mirror);
}

/// Cover with a play mark, and the song beside it.
class _Heading extends StatelessWidget {
  const _Heading({required this.song});

  final SongExtra song;

  static const ink = Colors.white;

  /// Secondary words: white, a little thinner, still 4.5 to 1 on the veil.
  static final soft = Colors.white.withValues(alpha: 0.9);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Artwork(url: song.art, size: 64, radius: 12),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, size: 20, color: ink),
            ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
              ),
              if (song.artist.isNotEmpty)
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.bodyMedium?.copyWith(color: soft),
                ),
              if (song.durMs > 0) Text(formatDuration(song.durMs), style: theme.bodySmall?.copyWith(color: soft)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Play now, add to queue and like, each only for whoever may use it, and as the room stands for the song.
class _Actions extends StatelessWidget {
  const _Actions({required this.controller, required this.song});

  final RoomController controller;
  final SongExtra song;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final track = song.track;
    final queued = snapshot.isQueued(track);
    final current =
        queued && snapshot.phase != 'idle' && snapshot.current != null && sameSong(snapshot.current!, track);
    return Row(
      children: [
        if (current)
          Expanded(
            child: _Pill(
              key: const ValueKey('song-card-playing'),
              label: S.chatSongPlaying,
              leading: Equalizer(active: controller.isPlaying, color: Colors.white, size: 14),
            ),
          )
        else ...[
          // Whoever may only add songs is not offered to play one
          if (snapshot.canControl) ...[
            Expanded(
              child: _Pill(
                key: const ValueKey('song-card-play'),
                label: S.chatSongPlayNow,
                filled: true,
                onTap: () {
                  HapticFeedback.selectionClick();
                  controller.playNowInRoom(track);
                },
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: _Pill(
              key: const ValueKey('song-card-add'),
              label: queued ? S.chatSongQueued : S.addToQueue,
              onTap: queued
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      controller.add(track);
                    },
            ),
          ),
        ],
        _Heart(track: track),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, this.onTap, this.leading, this.filled = false});

  final String label;
  final VoidCallback? onTap;
  final Widget? leading;

  /// The main one of the buttons: white, with dark words.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final ink = filled && on ? Colors.black87 : Colors.white.withValues(alpha: on || leading != null ? 1 : 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: on,
        label: label,
        excludeSemantics: true,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled && on ? Colors.white : Colors.white.withValues(alpha: on ? 0.22 : 0.12),
            borderRadius: BorderRadius.circular(18),
          ),
          // A long word in another language shrinks to fit rather than overflow
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 6)],
                Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: ink, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Heart extends StatelessWidget {
  const _Heart({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final liked = library.isLikedSong(track);
        return IconButton(
          key: const ValueKey('song-card-like'),
          onPressed: () {
            HapticFeedback.selectionClick();
            library.toggleLike(track);
          },
          tooltip: liked ? S.unlike : S.like,
          visualDensity: VisualDensity.compact,
          icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 22, color: Colors.white),
        );
      },
    );
  }
}
