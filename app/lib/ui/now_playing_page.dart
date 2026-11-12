import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'chat_sheet.dart';
import 'collection_screen.dart' show openCollection;
import 'members_sheet.dart';
import 'player/lyrics_view.dart';
import 'player/up_next_view.dart';
import 'player/video_controls.dart';
import 'player_sheet.dart';
import 'song_info_sheet.dart';
import 'scope.dart';
import 'sleep_sheet.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/edge_fade.dart';
import 'widgets/not_interested.dart';
import 'widgets/like_button.dart';
import 'widgets/marquee_text.dart';
import 'widgets/menu_lines.dart';
import 'widgets/motion.dart';
import 'widgets/download_actions.dart';
import 'widgets/playlist_picker.dart';
import 'widgets/queue_actions.dart';
import 'widgets/playback_bar.dart';
import 'widgets/transport.dart';
import 'widgets/video_frame.dart';
import 'widgets/video_view.dart';
import 'widgets/volume_bar.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/reactions.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Icons in the status bar and the navigation bar that show on the backdrop, light or dark like the app
    final icons = Theme.of(context).brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: icons,
        systemNavigationBarIconBrightness: icons,
      ),
      child: const _PlayerPage(),
    );
  }
}

class _PlayerPage extends StatelessWidget {
  const _PlayerPage();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    return PlayerPull(
      child: KeyedSubtree(
        key: sheet.pageRoot,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final current = controller.snapshot.current;
              if (current == null) {
                // The queue emptied while the sheet was open
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => sheet.close(),
                );
                return const SizedBox.shrink();
              }
              return _Body(controller: controller, current: current);
            },
          ),
        ),
      ),
    );
  }
}

/// Side of the full player's cover. It depends only on the screen, so the cover can be decoded
/// at this size before the player is ever opened.
double coverSize(MediaQueryData media) {
  // Everything except the cover needs about this much height (the seek bar, the buttons, the volume, the icons); the
  // cover takes what is left. Its side margins are the ones of Apple Music, 32 on each side
  final otherContent = 460.0 * _scaleOf(media);
  return [
    min(media.size.width, _columnMax) - 2 * _margin,
    media.size.height - media.padding.vertical - otherContent,
  ].reduce((a, b) => a < b ? a : b).clamp(140.0, _columnMax - 2 * _margin);
}

/// The side margin of the full player: the cover, the title, the seek bar and the buttons all start and end on it.
const _margin = 32.0;

/// How wide the upright player's column gets. On a tablet it does not stretch across the screen: a cover that is a
/// third of the screen is out of proportion with buttons the size of a phone's.
const _columnMax = 560.0;

/// Tablets get buttons a little bigger than a phone's, so that they keep up with the cover that has room to grow.
double _scaleOf(MediaQueryData media) =>
    media.size.shortestSide >= 600 ? 1.15 : 1.0;

/// What is left under the last row of buttons, on top of the system's own bar: the icons do not sit on the edge.
const _bottomGap = 28.0;

/// What the middle of the full player shows: the cover, or one of the panels that take its place.
enum _Panel { cover, lyrics, upNext }

class _Body extends StatefulWidget {
  const _Body({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  /// Opens on the panel the player bar of a wide screen was asked for, if it was.
  late _Panel _panel = switch (PlayerSheetScope.of(context).takePanel()) {
    PlayerPanel.lyrics => _Panel.lyrics,
    PlayerPanel.upNext => _Panel.upNext,
    null => _Panel.cover,
  };

  RoomController get _c => widget.controller;

  PlayerSheetController? _sheet;

  ThemeData? _baseTheme;
  ThemeData? _coverTheme;

  /// The theme of the app with the quiet colours made for what is on a cover. Made again only when the app's own
  /// theme changes: a new one at every build would make everything under it build again.
  ThemeData _onCoverTheme(BuildContext context) {
    final base = Theme.of(context);
    if (!identical(base, _baseTheme)) {
      _baseTheme = base;
      _coverTheme = base.copyWith(
        extensions: [SapocheTheme(context.palette.onCover)],
      );
    }
    return _coverTheme!;
  }

  /// Back with lyrics or the queue shown goes to the cover first; the player closes on the next one.
  bool _stepBack() {
    if (_panel == _Panel.cover) return false;
    setState(() => _panel = _Panel.cover);
    return true;
  }

  @override
  void dispose() {
    if (_sheet?.stepBack == _stepBack) _sheet?.stepBack = null;
    super.dispose();
  }

  /// A second touch on the button of the panel that is open goes back to the cover.
  void _show(_Panel panel) =>
      setState(() => _panel = _panel == panel ? _Panel.cover : panel);

  /// Whether the screen was on its side at the last look, to see the phone being turned.
  bool? _wasLandscape;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheet = PlayerSheetScope.of(context)..stepBack = _stepBack;
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final turned = _wasLandscape == false && landscape;
    _wasLandscape = landscape;
    // A phone turned on its side while the picture plays shows it across the whole screen, as video apps do. A tablet
    // has room for the picture beside the controls.
    if (turned &&
        !kIsWeb &&
        _c.snapshot.video &&
        media.size.shortestSide < 600 &&
        PlayerSheetScope.of(context).position.value == 1 &&
        !VideoFullScreen.open.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openVideoFullScreen(context, _c, turned: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The colours drift while the song plays, as Apple Music's do
        ListenableBuilder(
          listenable: _c.playState,
          builder: (context, _) => PlayerBackdrop(
            coverUrl: widget.current.thumb,
            moving: _c.isPlaying,
          ),
        ),
        // On its side the phone has no height for one column: the cover goes beside the controls instead. The
        // safe area also keeps both clear of a notch at the side. Reactions in the room fly up over all of it.
        // What is on the colours of the cover is in the colours made for it (`Palette.onCover`), not in the greys
        // of a plain page
        Theme(
          data: _onCoverTheme(context),
          child: ReactionShower(
            controller: _c,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, box) =>
                    box.maxWidth > box.maxHeight ? _wide(box) : _tall(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final current = widget.current;
    // On a tablet held upright the column does not stretch across the screen
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _columnMax),
        child: _tallColumn(p, current),
      ),
    );
  }

  Widget _tallColumn(Palette p, QueueEntry current) {
    return Column(
      children: [
        const SizedBox(height: 6),
        _Grabber(color: p.textTertiary.withValues(alpha: 0.5)),
        const SizedBox(height: 10),
        _ModePill(controller: _c),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: switch (_panel) {
              _Panel.cover => _CoverStage(
                key: const ValueKey('cover'),
                controller: _c,
                current: current,
              ),
              _ => _PanelStage(
                key: ValueKey(_panel),
                controller: _c,
                current: current,
                panel: _panel,
                onCover: () => setState(() => _panel = _Panel.cover),
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _margin),
          child: Column(
            children: [
              const SizedBox(height: 14),
              PlaybackBar(controller: _c),
              const SizedBox(height: 14),
              _TransportRow(controller: _c),
              const SizedBox(height: 6),
              // A browser has no volume of its own to set: the tab follows the computer's
              // Not while the lyrics or the queue are open: the queue gets the room (it shows a row more); the bar is
              // there again with the cover
              if (!kIsWeb && _panel == _Panel.cover) VolumeBar(controller: _c),
              const SizedBox(height: 4),
              _Toolbar(controller: _c, panel: _panel, onPanel: _show),
              if (_c.snapshot.inRoom) ...[
                const SizedBox(height: 6),
                _RoomStrip(controller: _c),
              ],
              const SizedBox(height: _bottomGap),
            ],
          ),
        ),
      ],
    );
  }

  /// A window with room in it (a browser), laid out as YouTube Music and Apple Music do on a computer: the picture, as
  /// large as the place allows, with the song under it on the left, the queue or the lyrics beside it over the whole
  /// height on the right, and the controls in one strip along the bottom, as wide as the window. Both halves are always
  /// there, so nothing is left hanging at the sides, and the picture of any shape has the song under it to fill the
  /// place above and below.
  Widget _roomy(BoxConstraints box) {
    final video = _c.snapshot.video;
    // The queue is what shows beside the picture until the lyrics are asked for
    final panel = _panel == _Panel.lyrics ? _Panel.lyrics : _Panel.upNext;
    const margin = 32.0;
    const gap = 32.0;
    // The song under the picture: its title and the strip of the room
    final caption = 16.0 + 64.0 + (_c.snapshot.inRoom ? 44.0 : 0.0);
    // The picture's half, as the layout below measures it, so that Audio or Video can stand over the picture
    final content = min(box.maxWidth, _roomyWidthMax);
    final left = (content - 2 * margin - gap) * (video ? 0.58 : 0.5);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _roomyWidthMax),
        child: Column(
          children: [
            // The way out on the edge, and Audio or Video over the picture it is about
            SizedBox(
              height: 48,
              child: Stack(
                children: [
                  const Positioned(left: 16, top: 0, child: _CloseButton()),
                  Positioned(
                    left: margin,
                    width: left,
                    top: 8,
                    child: Center(child: _ModePill(controller: _c)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(margin, 8, margin, 8),
                child: LayoutBuilder(
                  builder: (context, area) {
                    // A picture that is wide gets the larger half; a square one needs less than the height gives it
                    final left = (area.maxWidth - gap) * (video ? 0.58 : 0.5);
                    final room = max(120.0, area.maxHeight - caption);
                    final picture = video
                        ? min(left, room * 16 / 9)
                        : min(left, room);
                    return Row(
                      children: [
                        SizedBox(
                          width: left,
                          child: Center(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // A picture taller than wide (a phone's video) shrinks to the height there is
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: picture,
                                      maxHeight: room,
                                    ),
                                    child: _CoverArt(
                                      controller: _c,
                                      current: widget.current,
                                      size: picture,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: picture,
                                    child: _TitleRow(
                                      controller: _c,
                                      current: widget.current,
                                    ),
                                  ),
                                  if (_c.snapshot.inRoom) ...[
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      width: picture,
                                      child: _RoomStrip(controller: _c),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: gap),
                        Expanded(
                          child: switch (panel) {
                            _Panel.lyrics => LyricsView(
                              controller: _c,
                              track: widget.current,
                            ),
                            _ => UpNextView(controller: _c),
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // The controls, in one strip: the panels and more on the left, the buttons over the seek bar in the middle,
            // the volume on the right (not in a browser). The seek bar is as wide as the buttons need it, not as the window
            Padding(
              padding: const EdgeInsets.fromLTRB(margin, 0, margin, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 280,
                        child: _Toolbar(
                          controller: _c,
                          panel: panel,
                          // One of the two is always showing beside the picture, so these are a choice between two and
                          // not switches: touching the lit one leaves it lit
                          onPanel: (choice) => setState(() => _panel = choice),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 520,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TransportRow(controller: _c, playSize: 56),
                        const SizedBox(height: 6),
                        PlaybackBar(controller: _c, compact: true),
                      ],
                    ),
                  ),
                  Expanded(
                    child: kIsWeb
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerRight,
                            child: SizedBox(
                              width: 240,
                              child: VolumeBar(controller: _c),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The cover on the left, as tall as the screen allows; the controls, or a panel in their place, on the right. The
  /// title and the row of icons stay where they are when a panel opens: only what is between them changes.
  Widget _wide(BoxConstraints box) {
    if (box.maxHeight >= _roomyHeight && box.maxWidth >= _roomyWidth) {
      return _roomy(box);
    }
    const margin = 16.0;
    // As tall as the screen allows, but not the size of a wall on a big one
    final side = (box.maxHeight - 2 * margin).clamp(
      100.0,
      (box.maxWidth * 0.46).clamp(100.0, 480.0),
    );
    // A picture keeps its own proportions, so it gets a wider place than a square cover
    final left = _c.snapshot.video
        ? (side * 16 / 9).clamp(0.0, box.maxWidth * 0.52)
        : side;
    // The cover and the controls stay together in the middle of a wide window instead of drifting to its two sides
    final gutter = ((box.maxWidth - 1040) / 2).clamp(0.0, double.infinity);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24 + gutter, vertical: margin),
      child: Row(
        children: [
          SizedBox(
            width: left,
            height: box.maxHeight - 2 * margin,
            child: Center(
              child: _CoverArt(
                controller: _c,
                current: widget.current,
                size: side,
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: _WideSide(
              controller: _c,
              current: widget.current,
              panel: _panel,
              onPanel: _show,
            ),
          ),
        ],
      ),
    );
  }
}

/// A wide window at least this tall and this wide has room for the picture, the queue and the controls at once: a
/// browser, a tablet on its side, a television (a 1080p one is about 960 by 540 dp), not a phone on its side.
const _roomyHeight = 500.0;
const _roomyWidth = 800.0;

/// The roomy layout does not stretch further than this: on a very wide window it stays in the middle.
const _roomyWidthMax = 1600.0;

/// Previous, play and next: the pink disc between two plain glyphs, which is how Sapoche's player has always looked.
/// Shuffle and repeat live in Up Next, as in Apple Music.
class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.controller, this.playSize = 72});

  final RoomController controller;
  final double playSize;

  @override
  Widget build(BuildContext context) {
    final scale = _scaleOf(MediaQuery.of(context));
    return ListenableBuilder(
      listenable: controller.playState,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SkipButton(
            forward: false,
            onPressed: controller.prev,
            size: 52 * scale,
          ),
          PlayPauseButton(
            playing: controller.isPlaying,
            starting: controller.isStarting,
            onPressed: controller.togglePlay,
            size: playSize * scale,
          ),
          SkipButton(
            forward: true,
            onPressed: controller.next,
            size: 52 * scale,
          ),
        ],
      ),
    );
  }
}

/// Closes the player. The grabber of the upright player is too small a mark when the phone is on its side.
class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: PlayerSheetScope.of(context).close,
    tooltip: S.close,
    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
    color: context.palette.textSecondary,
  );
}

/// The right side of the player on its side. From top to bottom: the way out and Audio or Video, the song, then what
/// the player shows in the middle (the controls, lyrics or the queue), the row of icons, the room. Everything but the
/// middle keeps its place when a panel opens, as in Apple Music.
class _WideSide extends StatelessWidget {
  const _WideSide({
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  /// About the least height the column needs; a place shorter than this scales it down rather than overflow.
  static const _leastHeight = 380.0;

  /// The title, the controls and the icons keep 20 from the side, where the lines of the queue start.
  static Widget inset(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final scale = _scaleOf(MediaQuery.of(context));
    return LayoutBuilder(
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          // Never narrower than the row of icons needs, so that a narrow place scales it down instead
          width: box.maxWidth.clamp(340.0, 480.0 * scale),
          height: max(box.maxHeight, _leastHeight),
          child: Column(
            children: [
              inset(
                Row(
                  children: [
                    const _CloseButton(),
                    Expanded(
                      child: Center(child: _ModePill(controller: controller)),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              inset(_TitleRow(controller: controller, current: current)),
              const SizedBox(height: 4),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  // The queue has the 20 of its own at each side; lyrics get as much
                  child: switch (panel) {
                    _Panel.cover => inset(
                      _WideControls(
                        key: const ValueKey('controls'),
                        controller: controller,
                      ),
                    ),
                    _Panel.lyrics => Padding(
                      key: ValueKey(panel),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: LyricsView(controller: controller, track: current),
                    ),
                    _Panel.upNext => UpNextView(
                      key: ValueKey(panel),
                      controller: controller,
                    ),
                  },
                ),
              ),
              inset(
                _Toolbar(
                  controller: controller,
                  panel: panel,
                  onPanel: onPanel,
                ),
              ),
              if (controller.snapshot.inRoom) ...[
                const SizedBox(height: 4),
                inset(_RoomStrip(controller: controller)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the middle of the player on its side shows over the cover: the seek bar, the buttons and the volume.
class _WideControls extends StatelessWidget {
  const _WideControls({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      PlaybackBar(controller: controller),
      _TransportRow(controller: controller, playSize: 64),
      if (!kIsWeb) VolumeBar(controller: controller),
    ],
  );
}

/// The big cover (or the picture) with the title and the buttons that go with the song.
class _CoverStage extends StatelessWidget {
  const _CoverStage({
    super.key,
    required this.controller,
    required this.current,
  });

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final artSize = coverSize(MediaQuery.of(context));
    if (controller.snapshot.video) {
      // The picture takes all the height there is and keeps its own shape in it: a wide one is as wide as the
      // column, an upright one as tall as the place, never over the title and the controls
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: _margin),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                key: const ValueKey('video-place'),
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                child: _CoverArt(
                  controller: controller,
                  current: current,
                  size: artSize,
                ),
              ),
            ),
            _TitleRow(controller: controller, current: current),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // The cover and the title under it are one block, in the middle of the place above the controls, as in Apple
        // Music. The title keeps its size and the cover is what gives way when the screen is short
        final side = min(
          artSize,
          max(0.0, box.maxHeight - _titleHeight - _coverGap - 16),
        );
        // When even the title is a little too tall for the place (the keyboard is up), the block shrinks to fit
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: box.maxWidth - 2 * _margin,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: _CoverArt(
                      controller: controller,
                      current: current,
                      size: side,
                    ),
                  ),
                  // With no room left for the cover the title is all there is
                  SizedBox(height: side > 0 ? _coverGap : 0),
                  _TitleRow(
                    controller: controller,
                    current: current,
                    // A second line is for a screen where the cover keeps its size with it: one line of the title is
                    // taller than [_titleHeight] by about 32 dp
                    wrapLines:
                        side >= artSize &&
                            box.maxHeight - side - _coverGap - _titleHeight - 16 >= 32
                        ? 2
                        : 1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// About the height of the title, the artist and the heart under the cover.
const _titleHeight = 64.0;

/// The space between the cover and the title under it.
const _coverGap = 28.0;

/// The cover, or the picture when the song is shown as a video. It is the same in the upright player and on its side.
class _CoverArt extends StatelessWidget {
  const _CoverArt({
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
    // In a browser the picture is the frame of YouTube, which floats over this place
    if (kIsWeb && controller.snapshot.video) {
      return Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: VideoFrameSlot(
            key: sheet.pageCover,
            radius: 16,
            child: LayoutBuilder(
              builder: (context, box) => Artwork(
                url: current.thumb,
                size: box.maxWidth,
                radius: 16,
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
        overlay: VideoControls(controller: controller),
      );
    }
    return ListenableBuilder(
      listenable: controller.playState,
      // Paused covers shrink, like in Apple Music; the shadow settles with the cover rather than jumping ahead of it
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: controller.isPlaying ? 1 : 0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Transform.scale(
          scale: 0.86 + 0.14 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14 + 0.14 * t),
                  blurRadius: 18 + 18 * t,
                  offset: Offset(0, 8 + 10 * t),
                ),
              ],
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
            radius: 16,
            sharp: true,
            crossfade: true,
          ),
        ),
      ),
    );
  }
}

/// A panel in place of the cover, under a small cover and the title so that the song stays in view.
class _PanelStage extends StatelessWidget {
  const _PanelStage({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onCover,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final VoidCallback onCover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_margin, 14, 20, 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: onCover,
                child: kIsWeb && controller.snapshot.video
                    ? VideoFrameSlot(
                        radius: 10,
                        crop: true,
                        child: Artwork(
                          url: current.thumb,
                          size: 56,
                          radius: 10,
                        ),
                      )
                    : Artwork(url: current.thumb, size: 56, radius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      current.title,
                      style: theme.titleMedium,
                      rounds: MarqueeText.playerRounds,
                    ),
                    MarqueeText(
                      current.artist,
                      style: theme.bodyMedium?.copyWith(color: p.link),
                      rounds: MarqueeText.playerRounds,
                    ),
                  ],
                ),
              ),
              LikeButton(track: current, size: 24),
              _MoreButton(controller: controller, current: current),
            ],
          ),
        ),
        Expanded(
          child: switch (panel) {
            // The lines go up under the song above them: they fade out there, not cut off at its foot
            _Panel.lyrics => EdgeFade(
              top: 24,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _margin),
                child: LyricsView(controller: controller, track: current),
              ),
            ),
            // The queue has 20 of its own at each side, and the song above it 32: the difference is made up here
            _ => Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin - 20),
              child: UpNextView(controller: controller),
            ),
          },
        ),
      ],
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.controller,
    required this.current,
    this.wrapLines = 1,
  });

  final RoomController controller;
  final QueueEntry current;

  /// How many lines the title may take before it runs: more than one only where the height has room for them, as the
  /// cover of a phone's player does while it keeps its size.
  final int wrapLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                current.title,
                style: theme.headlineSmall,
                rounds: MarqueeText.playerRounds,
                wrapLines: wrapLines,
              ),
              const SizedBox(height: 2),
              _ArtistLine(controller: controller, current: current),
            ],
          ),
        ),
        LikeButton(track: current, size: 26),
        _MoreButton(controller: controller, current: current),
      ],
    );
  }
}

/// The artist of the song, and after it, small and still, how many watched it ("1.8B views"). It comes after a request
/// of its own, once the song has sound, so it only narrows the line when it arrives and nothing moves down.
class _ArtistLine extends StatefulWidget {
  const _ArtistLine({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

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
      color: track.isLocal ? p.textSecondary : p.link,
      fontWeight: FontWeight.w500,
    );
    final seen = AppScope.of(context).music.seenViews(track.videoId);
    final views = _views;
    final count =
        seen ??
        (views == null ? null : formatViews(views.count, plays: views.plays));
    final tail = theme.titleMedium?.copyWith(color: p.textSecondary);
    Widget artist(String name) {
      final line = MarqueeText(
        name,
        style: style,
        rounds: MarqueeText.playerRounds,
      );
      if (track.isLocal) return line;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openArtistOf(context, track),
        child: line,
      );
    }

    if (count == null) return artist(track.artist);
    return LayoutBuilder(
      builder: (context, box) {
        double width(String text, TextStyle? style) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout()).width;
        final name = width(track.artist, style);
        // The count gives way before the name does: whole or not at all (a count without its word, "734 M", reads as a
        // number of nothing). The name only moves when it is longer than the line by itself.
        final text = ' · $count';
        if (name + width(text, tail) <= box.maxWidth) {
          return Row(
            children: [
              Flexible(child: artist(track.artist)),
              Text(text, maxLines: 1, softWrap: false, style: tail),
            ],
          );
        }
        return artist(track.artist);
      },
    );
  }
}

/// Opens the page of the artist of [song], which YouTube Music is asked for; says so when it cannot be found.
Future<void> openArtistOf(BuildContext context, QueueEntry song) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  String? id;
  try {
    final radio = await AppScope.of(context).music.radio(song.videoId);
    id = radio.songOf(song.videoId)?.artistId;
  } on Object {
    // Said below
  }
  if (id == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.musicFailed)));
    return;
  }
  if (navigator.mounted) await openArtist(navigator.context, id);
}

/// Opens the page of the album [song] is on, which YouTube Music is asked for; says so when it is on none (a single
/// video, a song it does not know the album of).
Future<void> openAlbumOf(BuildContext context, QueueEntry song) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  MusicTrack? found;
  try {
    found = (await AppScope.of(context).music.radio(song.videoId))
        .songOf(song.videoId);
  } on Object {
    // Said below
  }
  final id = found?.albumId;
  if (id == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.noAlbum)));
    return;
  }
  if (navigator.mounted) {
    await openCollection(
      navigator.context,
      id: id,
      title: found?.album ?? song.title,
      thumb: song.thumb,
    );
  }
}

/// The "…" of the song: its info, its artist, a playlist to put it in, keeping it on the phone.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final snapshot = controller.snapshot;
    final who = current.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(current.addedBy);
    // A file on this phone has no YouTube artist or album, is not downloaded, has no link, and is not to be blocked
    final online = !current.isLocal;
    List<MenuLine> lines() => [
      MenuLine('info', Icons.info_outline_rounded, S.songInfo),
      if (online)
        MenuLine('artist', Icons.person_outline_rounded, S.goToArtist),
      if (online) MenuLine('album', Icons.album_outlined, S.goToAlbum),
      MenuLine('playlist', Icons.playlist_add_rounded, S.addToPlaylist),
      // Only where the room has a chat to send it to
      if (canSendToChat(controller, current))
        MenuLine('chat', Icons.chat_bubble_outline_rounded, S.songSendToChat),
      if (online) MenuLine('share', Icons.ios_share_rounded, S.shareSong),
      if (online && !kIsWeb)
        ...switch (library.downloadState(current.videoId)) {
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
        MenuLine('blocked', Icons.block_rounded, S.notInterested, apart: true),
    ];
    return SongMenuButton(
      track: current,
      lines: lines,
      onSelected: (value) => switch (value) {
        'info' => showSongInfo(
          context,
          current,
          addedBy: who.isEmpty ? null : who,
        ),
        'artist' => openArtistOf(context, current),
        'album' => openAlbumOf(context, current),
        'playlist' => showAddToPlaylist(context, [current]),
        'chat' => sendTrackToChat(context, current),
        'share' => controller.shareSong(current),
        'download' => startDownload(context, [current]),
        'blocked' => showNotInterested(context, current),
        _ => library.removeDownload(current.videoId),
      },
    );
  }
}

/// The icons of the toolbar when off. The tertiary text colour is too faint over the glow of a cover (under 2:1 over a
/// bright one in the dark theme); the main text colour, a little softened, reads like the rest of the player.
Color _toolTint(Palette p) => p.text.withValues(alpha: 0.8);

/// Lyrics, the queue, the sleep timer and where the sound goes: the things to reach for while listening.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scale = _scaleOf(MediaQuery.of(context));
    Widget button(IconData icon, String label, _Panel target) {
      final on = panel == target;
      return IconButton(
        onPressed: () => onPanel(target),
        tooltip: label,
        isSelected: on,
        icon: Icon(icon, size: 26 * scale),
        style: IconButton.styleFrom(
          foregroundColor: on ? p.onPrimary : _toolTint(p),
          backgroundColor: on ? p.primary : Colors.transparent,
          fixedSize: Size(52 * scale, 44 * scale),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        button(Icons.lyrics_outlined, S.lyrics, _Panel.lyrics),
        button(Icons.queue_music_rounded, S.upNext, _Panel.upNext),
        Flexible(child: _SleepButton(controller: controller)),
        // A browser plays through whatever the computer is set to: there is no list of outputs to open
        if (!kIsWeb) _OutputButton(controller: controller),
      ],
    );
  }
}

/// Opens the system's list to play somewhere else than on the phone: headphones, a speaker. Its icon says where the
/// sound goes, and it is lit up while that is not the phone itself.
class _OutputButton extends StatelessWidget {
  const _OutputButton({required this.controller});

  final RoomController controller;

  static IconData _icon(String kind) => switch (kind) {
    'headphones' => Icons.headphones_rounded,
    'bluetooth' => Icons.bluetooth_audio_rounded,
    'airplay' => Icons.airplay_rounded,
    'car' => Icons.directions_car_rounded,
    'other' => Icons.speaker_group_rounded,
    _ => Icons.smartphone_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final output = controller.output;
    final away = output.kind != 'speaker';
    return IconButton(
      onPressed: controller.pickOutput,
      tooltip: output.name.isEmpty ? S.playOn : '${S.playOn} · ${output.name}',
      icon: Icon(_icon(output.kind), size: 26),
      style: IconButton.styleFrom(
        foregroundColor: away ? p.onPrimary : _toolTint(p),
        backgroundColor: away ? p.primary : Colors.transparent,
        fixedSize: const Size(52, 44),
      ),
    );
  }
}

/// Opens the sleep timer; lit up, with the hour it stops at, while one is set.
class _SleepButton extends StatelessWidget {
  const _SleepButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sleep = controller.sleep;
    if (!sleep.on) {
      return IconButton(
        onPressed: () => showSleepSheet(context, controller),
        tooltip: S.sleepTimer,
        icon: const Icon(Icons.bedtime_outlined, size: 26),
        style: IconButton.styleFrom(
          foregroundColor: _toolTint(p),
          fixedSize: const Size(52, 44),
        ),
      );
    }
    return TextButton.icon(
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
class _ModePill extends StatelessWidget {
  const _ModePill({required this.controller});

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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
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
    );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
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
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

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
class _RoomStrip extends StatelessWidget {
  const _RoomStrip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    return Row(
      children: [
        // Who is here: tapping opens the list of members
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showMembersSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Semantics(
              label: S.listening(snapshot.listeningCount),
              child: AvatarStack(members: snapshot.members, size: 30, max: 3),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
                style: Theme.of(context).textTheme.labelMedium!.copyWith(
                  color: color,
                ),
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
