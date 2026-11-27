import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/app_settings.dart' show PlayerStyle;
import '../../data/connect/connect_wire.dart' show DeviceKind;
import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../format.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../chat_sheet.dart';
import '../members_sheet.dart';
import 'look.dart';
import 'up_next_view.dart' show RepeatButton, ShuffleButton;
import 'video_controls.dart';
import '../player_sheet.dart';
import '../connect_ui.dart';
import '../scope.dart';
import '../sleep_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/avatars.dart';
import '../widgets/explicit_badge.dart';
import '../tv/tv.dart' show TvScope;
import '../widgets/focus_nav.dart';
import '../widgets/touch_box.dart';
import '../widgets/track_links.dart';
import '../widgets/track_menu.dart';
import '../widgets/like_button.dart';
import '../widgets/menu_lines.dart' show MenuLine;
import '../widgets/marquee_text.dart';
import '../widgets/motion.dart';
import '../widgets/transport.dart';
import '../widgets/video_frame.dart';
import '../widgets/video_view.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/reactions.dart';

/// What the middle of the full player shows: the cover, or one of the panels that take its place.
enum NowPlayingPanel { cover, lyrics, upNext, comments }

/// Tablets get buttons a little bigger than a phone's, so that they keep up with the cover that has room to grow.
double playerScale(MediaQueryData media) =>
    media.size.shortestSide >= 600 ? 1.15 : 1.0;

/// Previous, play and next. By default the pink disc between two plain glyphs, which is how Sapoche's player has always
/// looked; the look of the player (`PlayerLook`) can make the disc white or take it away, and put shuffle and repeat
/// either side. Otherwise they live in Up Next, as in Apple Music.
class TransportRow extends StatelessWidget {
  const TransportRow({super.key, required this.controller, this.playSize = 72});

  final RoomController controller;
  final double playSize;

  @override
  Widget build(BuildContext context) {
    final scale = playerScale(MediaQuery.of(context));
    final look = PlayerLookScope.of(context);
    // Without a disc the glyph is all there is, so it gets the room the disc would have had
    final bare = look.disc == PlayDisc.bare;
    // Shuffle and repeat take a place each at the sides: the rest is a little smaller to keep them on a narrow screen
    final skip = bare
        ? 56.0
        : look.shuffleRepeat
        ? 40.0
        : 52.0;
    return ListenableBuilder(
      listenable: controller.playState,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (look.shuffleRepeat)
            ShuffleButton(controller: controller, bare: true),
          SkipButton(
            forward: false,
            onPressed: controller.prev,
            size: skip * scale,
            fast: look.rewindGlyphs,
          ),
          PlayPauseButton(
            playing: controller.isPlaying,
            starting: controller.isStarting,
            onPressed: controller.togglePlay,
            size:
                (bare
                    // The bare glyph is as large as the two beside it: the disc's size is for the glyph to be 56 across
                    ? playSize * 1.4
                    : look.shuffleRepeat
                    ? playSize * 0.9
                    : playSize) *
                scale,
            filled: !bare,
            white: look.disc == PlayDisc.white,
          ),
          SkipButton(
            forward: true,
            onPressed: controller.next,
            size: skip * scale,
            fast: look.rewindGlyphs,
          ),
          if (look.shuffleRepeat)
            RepeatButton(controller: controller, bare: true),
        ],
      ),
    );
  }
}

/// Closes the player. The grabber of the upright player is too small a mark when the phone is on its side.
class PlayerCloseButton extends StatelessWidget {
  const PlayerCloseButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: PlayerSheetScope.of(context).close,
    tooltip: S.close,
    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
    color: context.palette.textSecondary,
  );
}

/// The cover, or the picture when the song is shown as a video. It is the same in the upright player and on its side.
class PlayerCoverArt extends StatelessWidget {
  const PlayerCoverArt({
    super.key,
    required this.controller,
    required this.current,
    required this.size,
  });

  final RoomController controller;
  final QueueEntry current;
  final double size;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    final look = PlayerLookScope.of(context);
    // In a browser the picture is the frame of YouTube, which floats over this place
    if (kIsWeb && controller.snapshot.video) {
      return Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: VideoFrameSlot(
            key: sheet.pageCover,
            radius: look.coverRadius,
            child: LayoutBuilder(
              builder: (context, box) => Artwork(
                url: current.thumb,
                size: box.maxWidth,
                radius: look.coverRadius,
                sharp: true,
              ),
            ),
          ),
        ),
      );
    }
    if (controller.snapshot.video) {
      return VideoView(
        key: const ValueKey('video'),
        controller: controller,
        cover: current,
        // A TV has its own bar and buttons over the picture, which a remote reaches: the touch controls would be a second set
        overlay: TvScope.of(context)
            ? null
            : VideoControls(controller: controller),
      );
    }
    final radius = look.coverRadius;
    return ListenableBuilder(
      listenable: controller.playState,
      // Paused covers shrink, like in Apple Music; the shadow settles with the cover rather than jumping ahead of it
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: controller.isPlaying || !look.coverShrinks ? 1 : 0),
        duration: Motion.of(context, 420),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Transform.scale(
          scale: 0.86 + 0.14 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              // A cover that does not shrink lies flat on the ground, with no shadow under it
              boxShadow: context.shadowsOf([
                if (look.coverShrinks)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14 + 0.14 * t),
                    blurRadius: 18 + 18 * t,
                    offset: Offset(0, 8 + 10 * t),
                  ),
              ]),
            ),
            child: child,
          ),
        ),
        child: CoverSlot(
          controller: sheet,
          child: Artwork(
            key: sheet.pageCover,
            url: current.thumb,
            size: size,
            radius: radius,
            sharp: true,
            crossfade: true,
          ),
        ),
      ),
    );
  }
}

class PlayerTitleRow extends StatefulWidget {
  const PlayerTitleRow({
    super.key,
    required this.controller,
    required this.current,
    this.wrapLines = 1,
    this.showMore = true,
    this.dense = false,
    this.extra,
  });

  final RoomController controller;
  final QueueEntry current;

  /// The small player of a phone on its side: the title and the artist a size smaller, and the "…" with more in it
  /// (there is no row of icons to hold them).
  final bool dense;

  /// Something between the song and its heart: Audio or Video, in the small player.
  final Widget? extra;

  /// Whether the "…" of the song stands after the heart (the style of cards has it in the header instead).
  final bool showMore;

  /// How many lines the title may take before it runs: more than one only where the height has room for them, as the
  /// cover of a phone's player does while it keeps its size.
  final int wrapLines;

  @override
  State<PlayerTitleRow> createState() => _PlayerTitleRowState();
}

class _PlayerTitleRowState extends State<PlayerTitleRow> {
  MusicTrack? _song;
  bool _waiting = false;
  String? _askedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ask();
  }

  @override
  void didUpdateWidget(PlayerTitleRow old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller && _waiting) {
      old.controller.removeListener(_ask);
      _waiting = false;
    }
    if (old.current.videoId != widget.current.videoId) {
      _song = null;
      _askedFor = null;
    }
    _ask();
  }

  @override
  void dispose() {
    if (_waiting) widget.controller.removeListener(_ask);
    super.dispose();
  }

  Future<void> _ask() async {
    final track = widget.current;
    if (track.isLocal) return;
    final showYear =
        PlayerLookScope.of(context).style == PlayerStyle.appleMusic;
    final needsRadio = !track.explicit || (showYear && track.year == null);
    if (!needsRadio) return;
    // Wait until the song has sound before calling the cached watch/next endpoint
    final starting = widget.controller.isStarting;
    if (starting != _waiting) {
      _waiting = starting;
      if (starting) {
        widget.controller.addListener(_ask);
      } else {
        widget.controller.removeListener(_ask);
      }
    }
    if (starting || _askedFor == track.videoId) return;
    _askedFor = track.videoId;
    try {
      final song = (await AppScope.of(context).music.radio(track.videoId))
          .songOf(track.videoId);
      if (mounted && widget.current.videoId == track.videoId && song != null) {
        setState(() => _song = song);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final p = context.palette;
    final look = PlayerLookScope.of(context);
    final current = widget.current;
    final dense = widget.dense;
    final explicit = current.explicit || (_song?.explicit ?? false);
    final rawYear = current.year ?? _song?.year;
    final year =
        look.style == PlayerStyle.appleMusic &&
            rawYear != null &&
            rawYear.isNotEmpty
        ? rawYear
        : null;
    final title = MarqueeText(
      current.title,
      style: dense
          ? theme.titleMedium?.copyWith(
              fontSize: look.star ? 17 : 16,
              fontWeight: FontWeight.w700,
            )
          : look.compactTitle
          ? theme.headlineSmall?.copyWith(fontSize: 18)
          : theme.headlineSmall,
      rounds: MarqueeText.playerRounds,
      wrapLines: widget.wrapLines,
    );
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (explicit)
                Row(
                  children: [
                    Flexible(child: title),
                    const SizedBox(width: 6),
                    ExplicitBadge(
                      size: dense ? 16 : 18,
                      color: p.textSecondary,
                    ),
                  ],
                )
              else
                title,
              SizedBox(height: dense ? 0 : 2),
              _ArtistLine(
                controller: widget.controller,
                current: current,
                dense: dense,
                year: year,
              ),
            ],
          ),
        ),
        ?widget.extra,
        LikeButton(track: current, size: dense ? 22 : 26, star: look.star),
        if (widget.showMore)
          PlayerMoreButton(
            controller: widget.controller,
            current: current,
            compact: dense,
          ),
      ],
    );
  }
}

/// The artist of the song, and after it, small and still, the release year (Full cover only) and how many watched it
/// ("1.8B views"). It comes after a request of its own, once the song has sound, so it only narrows the line when it
/// arrives and nothing moves down.
class _ArtistLine extends StatefulWidget {
  const _ArtistLine({
    required this.controller,
    required this.current,
    this.dense = false,
    this.year,
  });

  final RoomController controller;
  final QueueEntry current;
  final bool dense;
  final String? year;

  @override
  State<_ArtistLine> createState() => _ArtistLineState();
}

class _ArtistLineState extends State<_ArtistLine> {
  ({int count, bool plays})? _views;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(_ArtistLine old) {
    super.didUpdateWidget(old);
    if (old.current.videoId != widget.current.videoId) {
      _views = null;
      _ask();
    }
  }

  /// Whether it is waiting for the song to have sound (it listens to the controller until it does).
  bool _waiting = false;

  @override
  void dispose() {
    if (_waiting) widget.controller.removeListener(_ask);
    super.dispose();
  }

  Future<void> _ask() async {
    final track = widget.current;
    if (track.isLocal) return;
    // The start of a song has the network to itself: the count is asked for once it has sound
    final starting = widget.controller.isStarting;
    if (starting != _waiting) {
      _waiting = starting;
      if (starting) {
        widget.controller.addListener(_ask);
      } else {
        widget.controller.removeListener(_ask);
      }
    }
    if (starting) return;
    // A list that showed the song has said already how many watched it, and that is the number
    if (AppScope.of(context).music.seenViews(track.videoId) != null) return;
    final views = await AppScope.of(context).music.viewCount(track);
    if (mounted && widget.current.videoId == track.videoId) {
      setState(() => _views = views);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final track = widget.current;
    // A file on this phone has no YouTube artist to go to, so its name is not made to look like a link
    final style = theme.titleMedium?.copyWith(
      // The pink accent is 2.8:1 on a peach cover: a name that opens a page is in the deep shade of it in the light
      // theme (see Palette.link), and in the accent itself in the dark one
      color: track.isLocal || PlayerLookScope.of(context).quietArtist
          ? p.textSecondary
          : p.link,
      fontWeight: FontWeight.w500,
      fontSize: widget.dense ? 13 : null,
    );
    final seen = AppScope.of(context).music.seenViews(track.videoId);
    final views = _views;
    final count =
        seen ??
        (views == null ? null : formatViews(views.count, plays: views.plays));
    final year = widget.year;
    final tail = theme.titleMedium?.copyWith(
      color: p.textSecondary,
      fontSize: widget.dense ? 13 : null,
    );
    Widget artist(String name) {
      final line = MarqueeText(
        name,
        style: style,
        rounds: MarqueeText.playerRounds,
      );
      if (track.isLocal) return line;
      return FocusTap(onTap: () => openArtistOf(context, track), child: line);
    }

    // When the line is tight, drop the year first, then the count, and never cut the artist to keep either.
    final candidates = <String>[
      if (year != null && count != null) '$year · $count',
      ?count,
      if (year != null && count == null) year,
    ];
    if (candidates.isEmpty) return artist(track.artist);
    return LayoutBuilder(
      builder: (context, box) {
        double width(String text, TextStyle? style) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout()).width;
        if (track.artist.isEmpty) {
          for (final item in candidates) {
            if (width(item, tail) <= box.maxWidth) {
              return Text(item, maxLines: 1, softWrap: false, style: tail);
            }
          }
          return artist(track.artist);
        }
        final name = width(track.artist, style);
        for (final item in candidates) {
          final text = ' · $item';
          if (name + width(text, tail) <= box.maxWidth) {
            return Row(
              children: [
                Flexible(child: artist(track.artist)),
                Text(text, maxLines: 1, softWrap: false, style: tail),
              ],
            );
          }
        }
        return artist(track.artist);
      },
    );
  }
}

/// The "…" of the song: the menu every song row has, without putting the song that is playing on the queue.
class PlayerMoreButton extends StatelessWidget {
  const PlayerMoreButton({
    super.key,
    required this.controller,
    required this.current,
    this.compact = false,
  });

  final RoomController controller;
  final QueueEntry current;

  /// The small player has no row of icons: the comments, where the sound goes and the sleep timer are in the menu.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final who = current.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(current.addedBy);
    final extra = [
      if (compact)
        MenuLine('comments', Icons.comment_outlined, S.youtubeComments),
      if (compact && showsConnectButton(context))
        MenuLine('output', connectLook(context, controller).icon, connectLook(context, controller).tooltip),
      if (compact)
        MenuLine(
          'sleep',
          controller.sleep.on ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          sleepMenuLabel(context, controller),
        ),
    ];
    return TrackMenu(
      track: current,
      addedBy: who.isEmpty ? null : who,
      extra: extra,
      onExtra: (value) => switch (value) {
        'sleep' => showSleepSheet(context, controller),
        'output' => openConnect(context, controller),
        'comments' => PlayerLookScope.panelOf(
          context,
        )?.call(NowPlayingPanel.comments),
        _ => null,
      },
    );
  }
}

/// The icons of the toolbar when off. The tertiary text colour is too faint over the glow of a cover (under 2:1 over a
/// bright one in the dark theme); the main text colour, a little softened, reads like the rest of the player.
Color _toolTint(Palette p) => p.text.withValues(alpha: 0.8);

/// Lyrics, the queue, the comments, the sleep timer and where the sound goes: the things to reach for while listening.
class PlayerToolbar extends StatelessWidget {
  const PlayerToolbar({
    super.key,
    required this.controller,
    required this.panel,
    required this.onPanel,
    this.kind,
  });

  final RoomController controller;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;

  /// Which buttons; the look of the player says when this is null.
  final ToolbarKind? kind;

  /// Room the lit sleep timer needs to say the hour it stops at, beside the other buttons; narrower, it is a lit icon.
  static const _pillWidth = 112.0;

  /// Between the pill and the thumb of a lit button in it: the thumb is round like the pill, 3 smaller all round.
  static const _frameInset = 3.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scale = playerScale(MediaQuery.of(context));
    // A browser plays through whatever the computer is set to: it has the button only to move the sound to another device
    final kind = this.kind ?? PlayerLookScope.of(context).toolbar;
    final connectShown = showsConnectButton(context);
    final count = connectShown ? 5 : 4;
    return LayoutBuilder(
      builder: (context, box) {
        // Five buttons of 52 are 260 wide: more than a phone of 320 dp leaves between the margins of the player
        // The thin lines between the buttons of the pill (kind `plain`) take a little room of their own
        final slot = min(
          52.0 * scale,
          (box.maxWidth -
                  (kind == ToolbarKind.plain ? 4 + 2 * _frameInset : 0)) /
              count,
        );
        // In the pill (kind `plain`) a lit button is a thumb inside the frame, not a slab as high as the frame
        // (as high as the pill was before the frame: a button is laid out 48 high at least, and the pill is 48)
        final height = kind == ToolbarKind.plain
            ? max(48.0, 44 * scale) - 2 * _frameInset
            : 44 * scale;
        Widget button(IconData icon, String label, NowPlayingPanel target) {
          final on = panel == target;
          return IconButton(
            onPressed: () => onPanel(target),
            tooltip: label,
            isSelected: on,
            icon: Icon(icon, size: 26 * scale),
            style: IconButton.styleFrom(
              foregroundColor: on ? p.onPrimary : _toolTint(p),
              backgroundColor: on ? p.primary : Colors.transparent,
              fixedSize: Size(slot, height),
              tapTargetSize: kind == ToolbarKind.plain
                  ? MaterialTapTargetSize.shrinkWrap
                  : null,
            ),
          );
        }

        final current = controller.snapshot.current;
        if (kind == ToolbarKind.face) {
          return Row(
            children: [
              if (connectShown) ConnectButton(controller: controller, width: slot),
              SleepButton(controller: controller, width: slot, pill: false),
              button(
                Icons.comment_outlined,
                S.youtubeComments,
                NowPlayingPanel.comments,
              ),
              const Spacer(),
              if (current != null)
                IconButton(
                  onPressed: () => showAddToPlaylist(context, [current]),
                  tooltip: S.addToPlaylist,
                  icon: Icon(Icons.playlist_add_rounded, size: 28 * scale),
                  style: IconButton.styleFrom(
                    foregroundColor: _toolTint(p),
                    fixedSize: Size(slot, 44 * scale),
                  ),
                ),
              button(
                Icons.queue_music_rounded,
                S.upNext,
                NowPlayingPanel.upNext,
              ),
            ],
          );
        }
        if (kind == ToolbarKind.plain) {
          // The line between two buttons goes while either is lit: the thumb has its own edge there
          Widget divider(bool hidden) => SizedBox(
            height: 28,
            child: VerticalDivider(
              width: 1,
              color: p.text.withValues(alpha: hidden ? 0 : 0.18),
            ),
          );
          // One pill for all of them: lyrics, where the sound goes, the sleep timer, the comments and the queue
          final items = [
            button(Icons.lyrics_outlined, S.lyrics, NowPlayingPanel.lyrics),
            if (connectShown)
              ConnectButton(controller: controller, width: slot, height: height),
            SleepButton(
              controller: controller,
              width: slot,
              height: height,
              pill: false,
            ),
            button(
              Icons.comment_outlined,
              S.youtubeComments,
              NowPlayingPanel.comments,
            ),
            button(Icons.queue_music_rounded, S.upNext, NowPlayingPanel.upNext),
          ];
          final lit = [
            panel == NowPlayingPanel.lyrics,
            if (connectShown) connectLook(context, controller).lit,
            controller.sleep.on,
            panel == NowPlayingPanel.comments,
            panel == NowPlayingPanel.upNext,
          ];
          return Center(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: p.veilStrong,
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.all(_frameInset),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) divider(lit[i - 1] || lit[i]),
                      items[i],
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            button(Icons.lyrics_outlined, S.lyrics, NowPlayingPanel.lyrics),
            button(Icons.queue_music_rounded, S.upNext, NowPlayingPanel.upNext),
            // Not the bubble of the room's chat, which is a different thing
            button(
              Icons.comment_outlined,
              S.youtubeComments,
              NowPlayingPanel.comments,
            ),
            SleepButton(
              controller: controller,
              width: slot,
              pill: box.maxWidth - (count - 1) * slot >= _pillWidth,
            ),
            if (connectShown) ConnectButton(controller: controller, width: slot),
          ],
        );
      },
    );
  }
}

/// Lyrics or the queue as a button at the end of the row of buttons of the small player: lit while its panel is open, and
/// a second touch on it goes back to the cover.
class PanelButton extends StatelessWidget {
  const PanelButton({
    super.key,
    required this.icon,
    required this.label,
    required this.target,
    required this.panel,
    required this.onPanel,
  });

  final IconData icon;
  final String label;
  final NowPlayingPanel target;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final on = panel == target;
    return IconButton(
      onPressed: () => onPanel(target),
      tooltip: label,
      isSelected: on,
      icon: Icon(icon, size: 24),
      style: IconButton.styleFrom(
        foregroundColor: on ? p.onPrimary : _toolTint(p),
        backgroundColor: on ? p.primary : Colors.transparent,
        fixedSize: const Size(44, 44),
      ),
    );
  }
}

/// The row of buttons of the small player of a phone on its side: previous, play, next, and what the style puts at either
/// end of them (Lyrics and Up next, or shuffle and repeat). 52 high, the discs a little smaller than the upright player's.
class CompactTransport extends StatelessWidget {
  const CompactTransport({
    super.key,
    required this.controller,
    required this.leading,
    required this.trailing,
  });

  final RoomController controller;
  final Widget leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final look = PlayerLookScope.of(context);
    final bare = look.disc == PlayDisc.bare;
    return SizedBox(
      height: 52,
      child: ListenableBuilder(
        listenable: controller.playState,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            leading,
            SkipButton(
              forward: false,
              onPressed: controller.prev,
              size: bare ? 32 : 28,
              fast: look.rewindGlyphs,
            ),
            PlayPauseButton(
              playing: controller.isPlaying,
              starting: controller.isStarting,
              onPressed: controller.togglePlay,
              size: bare ? 52 : 50,
              filled: !bare,
              white: look.disc == PlayDisc.white,
            ),
            SkipButton(
              forward: true,
              onPressed: controller.next,
              size: bare ? 32 : 28,
              fast: look.rewindGlyphs,
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// The cover, or the picture, in the place the small player keeps for it: as large as the place allows, left out when
/// what is left is under 96 (a cover that small shows nothing). A picture is as wide as the place and 16 to 9.
class CompactCover extends StatelessWidget {
  const CompactCover({
    super.key,
    required this.controller,
    required this.current,
    this.maxSide = 480,
  });

  final RoomController controller;
  final QueueEntry current;
  final double maxSide;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (controller.snapshot.video) {
        if (box.maxHeight < 54) return const SizedBox.shrink();
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxHeight * 16 / 9),
            child: PlayerCoverArt(
              controller: controller,
              current: current,
              size: box.maxWidth,
            ),
          ),
        );
      }
      // A little room under it for its shadow, where it has one
      final shadow = PlayerLookScope.of(context).coverShrinks ? 10.0 : 0.0;
      final side = min(box.maxHeight - shadow, min(box.maxWidth, maxSide));
      if (side < 96) return const SizedBox.shrink();
      return Center(
        child: PlayerCoverArt(
          controller: controller,
          current: current,
          size: side,
        ),
      );
    },
  );
}

/// The device the sound comes out of, under the row of buttons: the headphones or speaker it goes to when it is not the
/// phone's own, else this phone's name. Set like the line of the sound's quality above the seek bar, with room of its
/// own between it and the buttons. Not in a browser, which plays through whatever the computer is set to.
class DeviceLine extends StatelessWidget {
  const DeviceLine({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final output = controller.output;
    final other = connectOf(context)?.activeDevice;
    final elsewhere = controllingAnother(context) && other != null;
    final name = elsewhere
        ? S.playingOn(other.info?.name ?? '')
        : output.kind != 'speaker' && output.name.isNotEmpty
        ? output.name
        : controller.profile.device;
    if ((kIsWeb && !elsewhere) || name.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            elsewhere
                ? deviceIcon(other.info?.kind ?? DeviceKind.phone)
                : Icons.speaker_phone_rounded,
            size: 14,
            color: elsewhere ? context.palette.primary : context.palette.textSecondary,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: elsewhere ? context.palette.primary : context.palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the list of devices to play on: this one, the person's others, and the system's own outputs. Its icon says where
/// the sound goes (the device that plays while another does, else headphones, a speaker), and it is lit up while that is not
/// this device's own speaker.
class ConnectButton extends StatelessWidget {
  const ConnectButton({
    super.key,
    required this.controller,
    this.width = 52,
    this.height = 44,
  });

  final RoomController controller;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final connect = connectOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, ?connect]),
      builder: (context, _) {
        final p = context.palette;
        final look = connectLook(context, controller);
        return IconButton(
          onPressed: () => openConnect(context, controller),
          tooltip: look.tooltip,
          icon: Icon(look.icon, size: 26),
          style: IconButton.styleFrom(
            foregroundColor: look.lit ? p.onPrimary : _toolTint(p),
            backgroundColor: look.lit ? p.primary : Colors.transparent,
            fixedSize: Size(width, height),
            // In the pill the button is laid out as high as it is drawn: the pill has the 48
            tapTargetSize: height < kMinInteractiveDimension
                ? MaterialTapTargetSize.shrinkWrap
                : null,
          ),
        );
      },
    );
  }
}

/// Opens the sleep timer; lit up, with the hour it stops at, while one is set (where there is room for the hour).
class SleepButton extends StatelessWidget {
  const SleepButton({
    super.key,
    required this.controller,
    required this.width,
    required this.pill,
    this.height = 44,
  });

  final RoomController controller;
  final double width;
  final double height;

  /// Whether there is room to say the hour; without it a timer that is set is only lit.
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sleep = controller.sleep;
    if (sleep.on && pill) {
      return Flexible(
        child: TextButton.icon(
          onPressed: () => showSleepSheet(context, controller),
          icon: const Icon(Icons.bedtime_outlined, size: 20),
          label: Text(
            sleepLabel(context, sleep),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            foregroundColor: p.onPrimary,
            backgroundColor: p.primary,
            shape: const StadiumBorder(),
          ),
        ),
      );
    }
    return IconButton(
      onPressed: () => showSleepSheet(context, controller),
      tooltip: sleep.on ? sleepLabel(context, sleep) : S.sleepTimer,
      icon: const Icon(Icons.bedtime_outlined, size: 26),
      style: IconButton.styleFrom(
        foregroundColor: sleep.on ? p.onPrimary : _toolTint(p),
        backgroundColor: sleep.on ? p.primary : Colors.transparent,
        fixedSize: Size(width, height),
        // In the pill the button is laid out as high as it is drawn: the pill has the 48
        tapTargetSize: height < kMinInteractiveDimension
            ? MaterialTapTargetSize.shrinkWrap
            : null,
      ),
    );
  }
}

/// What a touch on Audio or Video does. The picture is this device's own choice and follows at once. The song also
/// changes to its other release (the music video, or the audio release) like YouTube Music's switch does: outside a
/// room for this device, in a room for everybody, because the queue is shared. A room only goes to the video
/// that way, not back: somebody else may be watching it.
Future<void> _chooseMode(BuildContext context, bool video) async {
  final controller = AppScope.roomOf(context);
  final music = AppScope.of(context).music;
  final messenger = ScaffoldMessenger.of(context);
  final snapshot = controller.snapshot;
  final current = snapshot.current;
  if (video == snapshot.video) return;
  await controller.setVideoMode(video);
  if (current == null ||
      (snapshot.inRoom && (!video || !snapshot.canControl))) {
    return;
  }
  MusicTrack? other;
  try {
    // Already the release asked for? A video that was reached from its audio release is known to be one
    if (video || music.audioOf(current) == null) {
      if (await music.isAudioRelease(current) == !video) return;
    }
    other = await music.otherRelease(current, video: video);
  } on Object {
    return; // no network: the picture alone
  }
  // The person may have moved on while YouTube was asked
  if (controller.snapshot.current?.id != current.id) return;
  if (other == null) {
    if (video) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.noVideoVersion)));
    }
    return;
  }
  await controller.swapVersion(current, other);
  if (snapshot.inRoom) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.videoForEveryone)));
  }
}

/// Audio or Video, like the switch at the top of YouTube Music's player: two icons, the one chosen filled.
class ModePill extends StatelessWidget {
  const ModePill({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    // A file on this phone has no video
    if (controller.snapshot.current?.isLocal ?? false) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final video = controller.snapshot.video;
    Widget segment(
      IconData icon,
      String label,
      bool selected,
      VoidCallback onTap,
    ) => Semantics(
      label: label,
      button: true,
      selected: selected,
      child: Tooltip(
        message: label,
        child: FocusTap(
          onTap: onTap,
          // The lit pill is 32 high; the place that answers a touch is the full 48
          child: SizedBox(
            width: 52,
            height: touchSize,
            child: Center(
              child: AnimatedContainer(
                duration: Motion.of(context, 200),
                width: 52,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? p.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: selected ? p.onPrimary : p.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        // The pill is drawn 38 high, 3 round the lit one, behind the full-height places that answer a touch
        Positioned.fill(
          top: (touchSize - 38) / 2,
          bottom: (touchSize - 38) / 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              segment(
                Icons.music_note_rounded,
                S.modeAudio,
                !video,
                () => _chooseMode(context, false),
              ),
              segment(
                Icons.smart_display_rounded,
                S.modeVideo,
                video,
                () => _chooseMode(context, true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One button for Audio or Video, for the styles that have no pill of the two over the cover: it shows the mode it goes
/// to (the picture while the song is heard, the cover while the picture shows) and does what the pill does. Not for a file
/// on this phone, which has no video. [onPicture] draws it as a dark disc with a white glyph, for over a cover.
class ModeToggle extends StatelessWidget {
  const ModeToggle({
    super.key,
    required this.controller,
    this.onPicture = false,
  });

  final RoomController controller;
  final bool onPicture;

  @override
  Widget build(BuildContext context) {
    if (controller.snapshot.current?.isLocal ?? false) {
      return const SizedBox.shrink();
    }
    final video = controller.snapshot.video;
    final p = context.palette;
    return IconButton(
      onPressed: () => _chooseMode(context, !video),
      tooltip: video ? S.modeAudio : S.modeVideo,
      icon: Icon(
        video ? Icons.music_note_rounded : Icons.ondemand_video_rounded,
        size: 24,
      ),
      style: IconButton.styleFrom(
        foregroundColor: onPicture ? Colors.white : p.textSecondary,
        backgroundColor: onPicture ? const Color(0x59000000) : null,
        fixedSize: const Size(44, 44),
      ),
    );
  }
}

class PlayerGrabber extends StatelessWidget {
  const PlayerGrabber({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 5,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// Who is listening and whether this phone is in step with them, with the ways to react and to write to them.
class RoomStrip extends StatelessWidget {
  const RoomStrip({super.key, required this.controller, this.compact = false});

  final RoomController controller;

  /// A strip of 32 for the small player of a phone on its side, which has no height to spare.
  final bool compact;

  @override
  Widget build(BuildContext context) =>
      compact ? SizedBox(height: 32, child: _row(context)) : _row(context);

  Widget _row(BuildContext context) {
    final snapshot = controller.snapshot;
    return Row(
      children: [
        // Who is here: tapping opens the list of members
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showMembersSheet(context),
          child: Padding(
            // 30 high faces and 9 above and below: the 48 a finger needs
            padding: EdgeInsets.symmetric(vertical: compact ? 3 : 9),
            child: Semantics(
              label: S.listening(snapshot.listeningCount),
              child: AvatarStack(
                members: snapshot.members,
                size: compact ? 26 : 30,
                max: 3,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ListenableBuilder(
              listenable: controller.player,
              builder: (context, _) => SyncChip(controller: controller),
            ),
          ),
        ),
        ReactButton(controller: controller),
        ChatButton(
          controller: controller,
          color: context.palette.textTertiary,
          size: 26,
        ),
      ],
    );
  }
}

/// Within this many ms of the room counts as in sync (the drift control aims well inside it).
const _inSyncMs = 80;

/// What the room's sync state is on this device: [label] in words, and [number] behind it (how far off, in ms or
/// seconds), which is for the person's own row of the list of members and not for the pill, where it changed with every
/// reading and was cut off when the label was long.
class SyncReading {
  const SyncReading(this.label, this.color, [this.number]);

  final String label;
  final Color color;
  final String? number;
}

/// The reading to show, or null when there is nothing to say: nobody else is listening, so there is nobody to be in
/// step with, or this device is stopped for a reason that is not the room's.
SyncReading? syncReading(RoomController controller, Palette p) {
  final snapshot = controller.snapshot;
  final player = controller.player.value;
  final drift = player.driftMs;
  if (snapshot.solo) return SyncReading(S.onYourOwn, p.primary);
  if (snapshot.listeningCount <= 1) return null;
  if (!controller.isPlaying) {
    // Stopped on this device by something outside the app while the room plays on: say so, and play catches up
    if (!(snapshot.wantsPlaying && player.heldBack)) return null;
    return SyncReading(S.pausedHere, p.textSecondary);
  }
  if (controller.isStarting) return SyncReading(S.buffering, p.textSecondary);
  // The network, not the app: this device plays a little behind the room until it can catch up
  if (player.weak && player.lagMs > _inSyncMs) {
    return SyncReading(
      S.weakNetworkLabel,
      p.textSecondary,
      S.behindBy(formatLag(player.lagMs)),
    );
  }
  if (drift == null) return SyncReading(S.syncing, p.textSecondary);
  if (drift.abs() <= _inSyncMs) {
    return SyncReading(S.inSync, p.success, formatDrift(drift));
  }
  // Off by an audible amount: the drift control is bringing this phone back
  return SyncReading(S.catchingUp, p.textSecondary, formatDrift(drift));
}

/// The room's sync state on this device, as a pill; a touch opens the list of members.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key, required this.controller, this.margin});

  final RoomController controller;

  /// Room around the pill, left out with it while there is nothing to say.
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final reading = syncReading(controller, context.palette);
    if (reading == null) return const SizedBox.shrink();
    final label = reading.label;
    final color = reading.color;
    return TouchBox(
      onTap: () => showMembersSheet(context),
      // The state changes its colour, in step with the words: the words themselves change with every reading
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.medium),
        margin: margin,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: Motion.of(context, Motion.medium),
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: AnimatedDefaultTextStyle(
                duration: Motion.of(context, Motion.medium),
                style: Theme.of(context).textTheme.labelMedium!
                    .copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: Text(label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
