import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/calm.dart';
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

/// A song shared in the chat, drawn as a card that is always square: a record sleeve with the cover, and the record itself half out of it
/// (it turns while the song plays), then the song, and small round buttons to play it, queue it or like it. Behind it the
/// cover blurred; over that a dark veil, so that the white words on it can be read whatever the cover is (a contrast of
/// 4.5 to 1 against a white one).
class ChatSongCard extends StatelessWidget {
  const ChatSongCard({super.key, required this.controller, required this.song});

  /// How much of the width of the screen the card takes, up to [maxWidth] dp; its height is the same.
  static const widthFactor = 0.63;
  static const maxWidth = 225.0;

  /// The veil over the cover and the colour of the chat: 0.58 of black leaves a white cover at about 0.15 of luminance.
  static const _veil = 0.58;

  final RoomController controller;
  final SongExtra song;

  static double widthIn(BuildContext context) => min(maxWidth, MediaQuery.sizeOf(context).width * widthFactor);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final look = ChatLookScope.of(context);
    final side = widthIn(context);
    return SizedBox(
      width: side,
      height: side,
      child: ClipRRect(
        key: const ValueKey('song-card'),
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: _Backdrop(url: song.art, tint: look?.from ?? p.primary),
            ),
            // The buttons are inside, and win the touch where they are
            GestureDetector(
              key: const ValueKey('song-card-body'),
              behavior: HitTestBehavior.opaque,
              onTap: () => showSongInfo(context, _entry),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The record takes what the words and the buttons leave of the square
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          child: ListenableBuilder(
                            listenable: controller,
                            builder: (context, _) =>
                                _Record(art: song.art, spinning: _isPlaying(controller, song.track)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _Details(song: song),
                    const SizedBox(height: 2),
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => _Actions(controller: controller, song: song),
                    ),
                  ],
                ),
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

/// Whether [track] is the song the room has at the front, and it is not idle.
bool _isCurrent(RoomController controller, Track track) {
  final snapshot = controller.snapshot;
  return snapshot.isQueued(track) &&
      snapshot.phase != 'idle' &&
      snapshot.current != null &&
      sameSong(snapshot.current!, track);
}

bool _isPlaying(RoomController controller, Track track) => _isCurrent(controller, track) && controller.isPlaying;

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

/// The song's name, and its artist and length.
class _Details extends StatelessWidget {
  const _Details({required this.song});

  final SongExtra song;

  static const ink = Colors.white;

  /// Secondary words: white, a little thinner, still 4.5 to 1 on the veil.
  static final soft = Colors.white.withValues(alpha: 0.9);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final length = song.durMs > 0 ? formatDuration(song.durMs) : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          song.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.labelLarge?.copyWith(color: ink, fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2),
        ),
        if (song.artist.isNotEmpty || length != null)
          Text(
            [if (song.artist.isNotEmpty) song.artist, ?length].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.bodySmall?.copyWith(color: soft, fontSize: 11),
          ),
      ],
    );
  }
}

/// The record sleeve (the cover, square) with the record half out of it on the right; the record turns while [spinning].
class _Record extends StatefulWidget {
  const _Record({required this.art, required this.spinning});

  final String? art;
  final bool spinning;

  /// The side of the sleeve, and how far the record comes out of it; drawn at this size and scaled to the room it has.
  static const sleeve = 120.0;
  static const out = 65.0;

  @override
  State<_Record> createState() => _RecordState();
}

class _RecordState extends State<_Record> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    Calm.on.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Record old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    Calm.on.removeListener(_sync);
    _turn.dispose();
    super.dispose();
  }

  /// Turns while the song plays, unless the system or the app wants calm; stays where it is when it stops.
  void _sync() {
    final move = widget.spinning && !MediaQuery.disableAnimationsOf(context) && !Calm.on.value;
    if (move && !_turn.isAnimating) {
      _turn.repeat();
    } else if (!move && _turn.isAnimating) {
      _turn.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    const sleeve = _Record.sleeve;
    const disc = sleeve - 6;
    return SizedBox(
      key: const ValueKey('song-card-record'),
      width: sleeve + _Record.out,
      height: sleeve,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: _Record.out,
            top: 3,
            child: RotationTransition(
              turns: _turn,
              child: SizedBox(
                width: disc,
                height: disc,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Positioned.fill(child: CustomPaint(painter: _DiscPainter())),
                    // The label of the record is a piece of the cover
                    Artwork(url: widget.art, size: disc * 0.38, radius: disc),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(2, 3)),
                ],
              ),
              child: Artwork(url: widget.art, size: sleeve, radius: 8),
            ),
          ),
        ],
      ),
    );
  }
}

/// The black vinyl: a dark disc with a faint sheen and the fine rings of its grooves.
class _DiscPainter extends CustomPainter {
  const _DiscPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          colors: [Color(0xFF111111), Color(0xFF2A2A2A), Color(0xFF111111), Color(0xFF2A2A2A), Color(0xFF111111)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: 0.07);
    for (var r = radius * 0.46; r < radius * 0.97; r += radius * 0.075) {
      canvas.drawCircle(center, r, groove);
    }
  }

  @override
  bool shouldRepaint(_DiscPainter old) => false;
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
    final current = _isCurrent(controller, track);
    return Row(
      children: [
        if (current)
          Flexible(
            child: _Playing(
              key: const ValueKey('song-card-playing'),
              child: Equalizer(active: controller.isPlaying, color: Colors.white, size: 14),
            ),
          )
        else ...[
          // Whoever may only add songs is not offered to play one
          if (snapshot.canControl)
            _Round(
              key: const ValueKey('song-card-play'),
              label: S.chatSongPlayNow,
              icon: Icons.play_arrow_rounded,
              filled: true,
              onTap: () {
                HapticFeedback.selectionClick();
                controller.playNowInRoom(track);
              },
            ),
          _Round(
            key: const ValueKey('song-card-add'),
            label: queued ? S.chatSongQueued : S.addToQueue,
            icon: queued ? Icons.playlist_add_check_rounded : Icons.playlist_add_rounded,
            onTap: queued
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    controller.add(track);
                  },
          ),
        ],
        _Heart(track: track),
      ],
    );
  }
}

/// A round button of the card: [filled] white with a dark mark for the main one, glass for the others, and dimmer when it
/// has nothing to do ([onTap] is null).
class _Round extends StatelessWidget {
  const _Round({super.key, required this.label, required this.icon, this.onTap, this.filled = false});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Tooltip(
      message: label,
      child: Semantics(
        button: on,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Without a use it still takes the touch, so that it does not open the song behind it
          onTap: onTap ?? () {},
          // The touch is wider than the circle, as the thumb is
          child: SizedBox(
            width: 38,
            height: 38,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled && on ? Colors.white : Colors.white.withValues(alpha: on ? 0.22 : 0.12),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: filled && on ? Colors.black87 : Colors.white.withValues(alpha: on ? 1 : 0.7),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The song is the one playing: a glass capsule with the equalizer and the word for it, where the buttons were.
class _Playing extends StatelessWidget {
  const _Playing({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(16)),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            const SizedBox(width: 6),
            Text(
              S.chatSongPlaying,
              maxLines: 1,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
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
        return _Round(
          key: const ValueKey('song-card-like'),
          label: liked ? S.unlike : S.like,
          icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          onTap: () {
            HapticFeedback.selectionClick();
            library.toggleLike(track);
          },
        );
      },
    );
  }
}
