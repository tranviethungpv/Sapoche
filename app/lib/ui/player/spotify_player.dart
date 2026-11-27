import 'dart:math';

import 'package:flutter/material.dart';

import '../../data/comments.dart';
import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../artist_page.dart' show openArtist;
import '../player_sheet.dart';
import '../connect_ui.dart';
import '../scope.dart';
import '../cover_glow.dart';
import '../widgets/like_button.dart';
import '../widgets/artwork.dart';
import '../widgets/low_rate_timer.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_bar.dart';
import '../widgets/transport.dart';
import '../widgets/volume_bar.dart';
import '../widgets/whole_pixel_clip.dart';
import 'classic_player.dart';
import 'look.dart';
import 'lyrics_ticker.dart';
import 'parts.dart';
import 'up_next_view.dart' show RepeatButton, ShuffleButton;
import '../widgets/motion.dart';

/// What the head of the card says the song is playing from: its album, else the room, else who made it (a song with no
/// album would have the head say only "Now playing"). Null where none of them is known.
String? _playingFrom(RoomController c, QueueEntry current, String? album) {
  if (album != null) return album;
  if (c.snapshot.inRoom) return S.room;
  final artist = current.artist.trim();
  return artist.isEmpty ? null : artist;
}

/// "NOW PLAYING · album" for the head of a player: the card's, and the TV's. The album comes when YouTube Music has said
/// which it is (the queue knows only the song).
class PlayingFromLine extends StatelessWidget {
  const PlayingFromLine({
    super.key,
    required this.controller,
    required this.current,
    this.textAlign = TextAlign.center,
  });

  final RoomController controller;
  final QueueEntry current;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return FutureBuilder<SongRadio>(
      future: current.isLocal
          ? null
          : AppScope.of(context).music.radio(current.videoId),
      builder: (context, async) {
        final album = async.data?.songOf(current.videoId)?.album;
        final line = _playingFrom(controller, current, album);
        return Text(
          line == null
              ? S.nowPlaying.toUpperCase()
              : '${S.nowPlaying.toUpperCase()} · $line',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: theme.labelSmall?.copyWith(
            color: p.textSecondary,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
          ),
        );
      },
    );
  }
}

/// The player of the style of cards: the face of the song (the cover, the seek bar, the buttons with shuffle and repeat
/// beside the play button) fills the screen, and below it, as the page is scrolled, are cards: the lyrics, the artist,
/// the queue, the comments. A card opens its page whole, which Back closes first. On a screen on its side the face is
/// shorter: the cards are under the cover and the song in a column that scrolls, and the buttons stay at the foot.
class SpotifyPlayer extends StatelessWidget {
  const SpotifyPlayer({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;
  final ValueChanged<NowPlayingPanel> onChoose;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => playerIsCompact(context, box.maxHeight)
        ? _Compact(
            controller: controller,
            current: current,
            panel: panel,
            onPanel: onPanel,
            onChoose: onChoose,
          )
        : _Tall(
            controller: controller,
            current: current,
            panel: panel,
            onPanel: onPanel,
            onChoose: onChoose,
            height: box.maxHeight,
          ),
  );
}

class _Tall extends StatefulWidget {
  const _Tall({
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
    required this.height,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;
  final ValueChanged<NowPlayingPanel> onChoose;
  final double height;

  @override
  State<_Tall> createState() => _TallState();
}

/// The space at each side of the cover, the bar and the buttons.
const _margin = 22.0;

/// How much of the first card shows at the foot of the face before the page is scrolled.
const _peek = 24.0;

class _TallState extends State<_Tall> {
  final _scroll = ScrollController();
  late final _physics = _PullPhysics(blocked: () => _pulling);

  /// Whether a pull down from the top of the page is closing the player.
  bool _pulling = false;

  RoomController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The page is a scroll view, so the pull that closes the player does not reach the sheet by itself: what a drag
  /// down still asks for at the top of the page is given to it. From then on, until the finger lets go or the player is
  /// back up, the page does not scroll (`_PullPhysics`): every movement of the finger, up as well as down, is the sheet's.
  /// Without that, a finger turned upwards would scroll the page under a sheet left half way, with its cover hanging
  /// where the pull had put it.
  bool _onScroll(ScrollNotification n) {
    final sheet = PlayerSheetScope.of(context);
    // Beside the pages the player is not pulled down
    if (PlayerLookScope.dockedOf(context)) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        (n.overscroll < 0 || _pulling)) {
      if (!_pulling) {
        _pulling = true;
        sheet.beginDrag();
      }
      sheet.dragBy(-n.overscroll, MediaQuery.sizeOf(context));
      // All the way up again and the finger still going up: the page is its own again
      if (n.overscroll > 0 && sheet.position.value >= 1) {
        _pulling = false;
        sheet.endDrag(0, startedClosed: false);
      }
    } else if (n is ScrollEndNotification && _pulling) {
      _pulling = false;
      sheet.endDrag(n.dragDetails?.primaryVelocity ?? 0, startedClosed: false);
    }
    return false;
  }

  Widget _face() {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final panel = widget.panel;
    final current = widget.current;
    // Beside the pages the card is narrow, and the cover is all it has to show
    final docked = PlayerLookScope.dockedOf(context);
    final margin = docked ? playerDockMargin : _margin;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerColumnMax),
        child: Column(
          children: [
            const SizedBox(height: 2),
            // The way out on the left, what is playing from in the middle, the "…" of the song on the right
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  // Beside the pages the player has no way out; the room it takes keeps the line in the middle
                  if (PlayerLookScope.dockedOf(context))
                    const SizedBox(width: 48)
                  else
                    const PlayerCloseButton(),
                  Expanded(
                    // The album, when YouTube Music has said which it is (the queue knows only the song)
                    child: FutureBuilder<SongRadio>(
                      future: current.isLocal
                          ? null
                          : AppScope.of(context).music.radio(current.videoId),
                      builder: (context, async) {
                        final album = async.data
                            ?.songOf(current.videoId)
                            ?.album;
                        // A song with no album shows who made it, as Spotify's "playing from" does
                        final line = _playingFrom(_c, current, album);
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              S.nowPlaying.toUpperCase(),
                              style: theme.labelMedium?.copyWith(
                                color: p.textSecondary,
                                letterSpacing: 0.8,
                              ),
                            ),
                            if (line != null)
                              Text(
                                line,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  ModeToggle(controller: _c),
                  PlayerMoreButton(controller: _c, current: current),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.of(context, 240),
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: switch (panel) {
                  NowPlayingPanel.cover => PlayerCoverStage(
                    key: const ValueKey('cover'),
                    controller: _c,
                    current: current,
                    margin: margin,
                    showMore: false,
                    // The cover is as wide as the title: what the rest of the face costs is kept to a little
                    gap: docked ? 10 : 14,
                    // The running line of the lyrics stands between the cover and the title, and costs its height
                    bottom: _c.snapshot.video ? 4 : 4 + 28 + 24,
                    betweenGap: 24,
                    lowered: true,
                    between: _c.snapshot.video
                        ? null
                        : LyricsTicker(controller: _c, track: current),
                  ),
                  _ => PlayerPanelStage(
                    key: ValueKey(panel),
                    controller: _c,
                    current: current,
                    panel: panel,
                    onCover: () => widget.onChoose(NowPlayingPanel.cover),
                  ),
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: margin),
              child: Column(
                children: [
                  const SizedBox(height: 2),
                  PlaybackBar(controller: _c),
                  const SizedBox(height: 4),
                  TransportRow(controller: _c),
                  PlayerToolbar(
                    controller: _c,
                    panel: panel,
                    onPanel: widget.onPanel,
                    kind: ToolbarKind.face,
                  ),
                  if (controllingAnother(context)) ...[
                    DeviceLine(controller: _c),
                    const SizedBox(height: 4),
                    VolumeBar(controller: _c),
                  ],
                  if (_c.snapshot.inRoom) ...[
                    const SizedBox(height: 6),
                    RoomStrip(controller: _c),
                  ],
                  SizedBox(height: docked ? 4 : 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A page held open (a panel) is one screen: the cards are for the cover
    if (widget.panel != NowPlayingPanel.cover) return _face();
    final cards = _Cards(
      controller: _c,
      current: widget.current,
      onChoose: widget.onChoose,
    );
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomScrollView(
            controller: _scroll,
            physics: _physics,
            slivers: [
              SliverToBoxAdapter(
                // The face stops a little short of the screen: the top edge of the lyrics card shows under it, to say there is
                // more below
                child: SizedBox(height: widget.height - _peek, child: _face()),
              ),
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: playerColumnMax,
                    ),
                    child: cards,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Past the cover the song stays in view: its name and the play button, held at the top
        ListenableBuilder(
          listenable: _scroll,
          builder: (context, _) {
            final past =
                _scroll.hasClients && _scroll.offset > widget.height - 220;
            return Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !past,
                child: AnimatedOpacity(
                  opacity: past ? 1 : 0,
                  duration: Motion.of(context, 160),
                  child: ExcludeSemantics(
                    excluding: !past,
                    child: _StickyHeader(
                      controller: _c,
                      current: widget.current,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The face of a phone on its side, a column that is short: "Playing from" in one line over a place that scrolls (the
/// cover and the song, then the cards), and the seek bar and the buttons held at the foot, with shuffle and repeat at the
/// ends of them. A panel opened from a card takes the place that scrolls, under a line with the song.
class _Compact extends StatelessWidget {
  const _Compact({
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;
  final ValueChanged<NowPlayingPanel> onChoose;

  RoomController get _c => controller;

  Widget _header(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            // The album, when YouTube Music has said which it is (the queue knows only the song)
            child: PlayingFromLine(controller: _c, current: current),
          ),
          SizedBox(
            width: 40,
            child: PlayerMoreButton(
              controller: _c,
              current: current,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cover = panel == NowPlayingPanel.cover;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerCompactWidthMax),
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Column(
            children: [
              if (cover)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _header(context),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.of(context, 240),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  child: cover
                      ? _Scrolling(
                          key: const ValueKey('cover'),
                          controller: _c,
                          current: current,
                          onChoose: onChoose,
                        )
                      : PlayerPanelStage(
                          key: ValueKey(panel),
                          controller: _c,
                          current: current,
                          panel: panel,
                          onCover: () => onChoose(NowPlayingPanel.cover),
                          compact: true,
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    PlaybackBar(controller: _c, inline: true),
                    CompactTransport(
                      controller: _c,
                      leading: ShuffleButton(controller: _c, bare: true),
                      trailing: RepeatButton(controller: _c, bare: true),
                    ),
                    if (_c.snapshot.inRoom)
                      RoomStrip(controller: _c, compact: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The column that scrolls in [_Compact]: the cover and the song, then the cards. The cover is as large as the place
/// leaves it after the song, with a little of the first card showing under, to say that there is more.
class _Scrolling extends StatelessWidget {
  const _Scrolling({
    super.key,
    required this.controller,
    required this.current,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;
  final ValueChanged<NowPlayingPanel> onChoose;

  /// The song under the cover, and what is left showing of the card under it.
  static const _title = 48.0;
  static const _peek = 16.0;

  @override
  Widget build(BuildContext context) {
    final video = controller.snapshot.video;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth - 32;
        final room = max(0.0, box.maxHeight - _title - 8 - _peek);
        final side = video
            ? min(room, width * 9 / 16)
            : min(width, max(room, 96.0));
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
            stops: [0, 0.88, 1],
          ).createShader(rect),
          // Under the mask: it ends on a whole pixel row, or the row it ends in is part unmasked
          child: WholePixelClip(child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                SizedBox(
                  height: side,
                  child: CompactCover(
                    controller: controller,
                    current: current,
                    maxSide: width,
                  ),
                ),
                const SizedBox(height: 8),
                PlayerTitleRow(
                  controller: controller,
                  current: current,
                  dense: true,
                  showMore: false,
                  extra: ModeToggle(controller: controller),
                ),
                _Cards(
                  controller: controller,
                  current: current,
                  onChoose: onChoose,
                  margin: 0,
                ),
              ],
            ),
          )),
        );
      },
    );
  }
}

class _StickyHeader extends StatelessWidget {
  const _StickyHeader({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.base,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_margin, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    current.title,
                    style: Theme.of(context).textTheme.titleMedium,
                    rounds: MarqueeText.playerRounds,
                  ),
                  Text(
                    current.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            LikeButton(track: current, size: 26),
            ListenableBuilder(
              listenable: controller.playState,
              builder: (context, _) => PlayPauseButton(
                playing: controller.isPlaying,
                starting: controller.isStarting,
                onPressed: controller.togglePlay,
                size: 44,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cards under the face. Each is a way into a page of the player, with a little of what is on it.
class _Cards extends StatelessWidget {
  const _Cards({
    required this.controller,
    required this.current,
    required this.onChoose,
    this.margin = _margin - 6,
  });

  final RoomController controller;
  final QueueEntry current;
  final ValueChanged<NowPlayingPanel> onChoose;

  /// The space at each side of the cards.
  final double margin;

  @override
  Widget build(BuildContext context) {
    final upNext = controller.snapshot.upNext;
    return Padding(
      padding: EdgeInsets.fromLTRB(margin, 8, margin, 32),
      child: Column(
        children: [
          _LyricsCard(
            controller: controller,
            current: current,
            onTap: () => onChoose(NowPlayingPanel.lyrics),
          ),
          if (!current.isLocal)
            _ArtistCard(
              key: ValueKey('artist-${current.videoId}'),
              track: current,
            ),
          if (upNext.isNotEmpty)
            _UpNextCard(
              songs: upNext.take(3).toList(),
              onTap: () => onChoose(NowPlayingPanel.upNext),
            ),
          _CommentsCard(
            key: ValueKey('comments-${current.videoId}'),
            current: current,
            onTap: () => onChoose(NowPlayingPanel.comments),
          ),
        ],
      ),
    );
  }
}

/// A card: a title, what is on the page it opens, a touch anywhere on it opens it.
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.onTap,
    this.trailing,
    this.color,
  });

  final String title;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: color ?? p.veilStrong,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: onTap != null,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                  const SizedBox(height: 10),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The lyrics, on a deep shade of the cover's colour, with a "Show" that opens them whole.
class _LyricsCard extends StatefulWidget {
  const _LyricsCard({
    required this.controller,
    required this.current,
    required this.onTap,
  });

  final RoomController controller;
  final QueueEntry current;
  final VoidCallback onTap;

  @override
  State<_LyricsCard> createState() => _LyricsCardState();
}

class _LyricsCardState extends State<_LyricsCard> {
  Color? _tone;

  bool? _light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final light = context.palette.brightness == Brightness.light;
    if (light == _light) return;
    _light = light;
    _load();
  }

  @override
  void didUpdateWidget(_LyricsCard old) {
    super.didUpdateWidget(old);
    if (old.current.thumb != widget.current.thumb) _load();
  }

  Future<void> _load() async {
    final url = widget.current.thumb;
    final tone = url == null
        ? null
        : await CoverGlow.ground(url, light: _light ?? false);
    if (mounted && widget.current.thumb == url) setState(() => _tone = tone);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final current = widget.current;
    final tone = _tone;
    return _Card(
      title: S.lyrics,
      onTap: widget.onTap,
      color: tone == null
          ? null
          : p.brightness == Brightness.dark
          ? Color.lerp(tone, Colors.black, 0.45)
          // In the light theme the card is the tint of the cover, a little deeper than the page behind it
          : Color.lerp(tone, Colors.black, 0.06),
      trailing: Text(
        S.show,
        style: theme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      child: FutureBuilder<Lyrics?>(
        key: ValueKey(current.videoId),
        future: AppScope.of(context).music.lyrics(current),
        builder: (context, snapshot) {
          final lyrics = snapshot.data;
          final style = theme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.3,
            color: lyrics == null ? p.textSecondary : p.text,
          );
          if (snapshot.connectionState != ConnectionState.done) {
            return Text('', style: style);
          }
          if (lyrics == null) return Text(S.noLyrics, style: style);
          // Lyrics with times run along with the song, the line being sung bright; without, the first lines
          if (lyrics.synced) {
            return _LiveLines(
              controller: widget.controller,
              lyrics: lyrics,
              style: style,
            );
          }
          return Text(
            (lyrics.plain ?? '').split('\n').take(5).join('\n'),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        },
      ),
    );
  }
}

/// A few lines of the lyrics round the one being sung: it is bright and the others dim, and the window moves on as
/// the song does (the lines of the page itself are in `LyricsView`).
class _LiveLines extends StatefulWidget {
  const _LiveLines({
    required this.controller,
    required this.lyrics,
    required this.style,
  });

  final RoomController controller;
  final Lyrics lyrics;
  final TextStyle? style;

  @override
  State<_LiveLines> createState() => _LiveLinesState();
}

class _LiveLinesState extends State<_LiveLines> {
  /// A line lights up a little before it is sung, as in the page of the lyrics.
  static const _leadMs = 250;

  /// How many lines show, and how many of them come before the one being sung.
  static const _shown = 5;
  static const _before = 1;

  late final LowRateTimer _ticker = LowRateTimer(
    const Duration(milliseconds: 200),
    _update,
  );
  int _active = 0;

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.player.addListener(_sync);
    _c.addListener(_sync);
    _active = _line();
    _ticker.run(_c.player.value.playing);
  }

  @override
  void dispose() {
    _c.player.removeListener(_sync);
    _c.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  int _line() => widget.lyrics.lineAt(_c.positionMs() + _leadMs) ?? 0;

  void _sync() {
    _ticker.run(_c.player.value.playing);
    _update();
  }

  void _update() {
    if (!mounted) return;
    final line = _line();
    if (line != _active) setState(() => _active = line);
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics.lines;
    // The window starts one line before the one being sung and keeps its size at the end of the song
    final start = (_active - _before)
        .clamp(0, max(0, lines.length - _shown))
        .toInt();
    final end = min(lines.length, start + _shown);
    return AnimatedSwitcher(
      duration: Motion.of(context, 300),
      child: Column(
        key: ValueKey(start),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = start; i < end; i++)
            if (lines[i].text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: AnimatedOpacity(
                  opacity: i == _active ? 1 : 0.5,
                  duration: Motion.of(context, 300),
                  child: Text(
                    lines[i].text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: widget.style,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// The artist of the song: a big picture with the name and how many follow, a touch goes to the artist's page. The
/// queue knows only the song, so who the artist is comes from YouTube Music (asked when the card is built, which is when
/// the page is scrolled near it).
class _ArtistCard extends StatefulWidget {
  const _ArtistCard({super.key, required this.track});

  final QueueEntry track;

  @override
  State<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<_ArtistCard> {
  Future<ArtistPage?>? _artist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _artist ??= _find();
  }

  Future<ArtistPage?> _find() async {
    final music = AppScope.of(context).music;
    try {
      final id = (await music.radio(widget.track.videoId))
          .songOf(widget.track.videoId)
          ?.artistId;
      return id == null ? null : await music.artist(id);
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return FutureBuilder<ArtistPage?>(
      future: _artist,
      builder: (context, snapshot) {
        final artist = snapshot.data;
        // A card with nothing to say is left out
        if (artist == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: p.veilStrong,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              button: true,
              child: InkWell(
                onTap: () => openArtist(context, artist.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) => Stack(
                        children: [
                          Artwork(
                            url: artist.thumb,
                            size: box.maxWidth / 1.5,
                            width: box.maxWidth,
                            radius: 0,
                            sharp: true,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x99000000),
                                    Color(0x00000000),
                                  ],
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Text(
                                  S.aboutArtist,
                                  style: theme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (artist.subscribers != null)
                            Text(
                              S.subscribers(artist.subscribers!),
                              style: theme.bodyMedium?.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({required this.songs, required this.onTap});

  final List<QueueEntry> songs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return _Card(
      title: S.upNext,
      onTap: onTap,
      child: Column(
        children: [
          for (final song in songs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Artwork(url: song.thumb, size: 44, radius: 6),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodyLarge,
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodySmall?.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CommentsCard extends StatefulWidget {
  const _CommentsCard({super.key, required this.current, required this.onTap});

  final QueueEntry current;
  final VoidCallback onTap;

  @override
  State<_CommentsCard> createState() => _CommentsCardState();
}

class _CommentsCardState extends State<_CommentsCard> {
  CommentsFeed? _feed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Asked for when the card is built, which is when the page is scrolled near it
    if (_feed == null) {
      _feed = AppScope.of(context).comments.feed(widget.current.videoId);
      _feed!.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed!;
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        if (feed.off) return const SizedBox.shrink();
        final first = feed.comments.isEmpty ? null : feed.comments.first;
        return _Card(
          title: S.youtubeComments,
          trailing: feed.total == null
              ? null
              : Text(
                  feed.total!,
                  style: theme.labelMedium?.copyWith(color: p.textSecondary),
                ),
          onTap: widget.onTap,
          child: first == null
              ? Text(
                  feed.failed
                      ? S.commentsFailed
                      : feed.loading
                      ? ''
                      : S.commentsNone,
                  style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      first.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.labelLarge?.copyWith(color: p.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      first.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodyMedium,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// Scrolling that clamps at both ends, and that while the player is being pulled down refuses every movement: it all
/// comes back as overscroll, which the page turns into the sheet's own movement (`_TallState._onScroll`).
class _PullPhysics extends ClampingScrollPhysics {
  const _PullPhysics({required this.blocked, super.parent});

  final bool Function() blocked;

  @override
  _PullPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullPhysics(blocked: blocked, parent: buildParent(ancestor));

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) =>
      blocked()
      ? value - position.pixels
      : super.applyBoundaryConditions(position, value);
}
