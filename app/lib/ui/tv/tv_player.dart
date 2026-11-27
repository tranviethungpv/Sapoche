import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/app_settings.dart' show PlayerStyle;
import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../player/classic_player.dart' show PlayerPanelStage;
import '../player/look.dart';
import '../player/parts.dart';
import '../player/spotify_player.dart' show PlayingFromLine;
import '../widgets/artwork.dart';
import '../widgets/focus_nav.dart';
import '../widgets/motion.dart';
import '../widgets/playback_bar.dart';

/// The full player on a TV: the whole screen, with the cover at the left and the song, its bar and its buttons at the
/// right, laid out once for the canvas of a TV. The three styles of the player share it and each keeps what makes it
/// itself: the cover (a card with a shadow, a flat one with square corners, one that fills the left half and fades into the
/// page), the discs of the buttons, the row of icons. Those come from [PlayerLook], which the pieces read themselves.
/// Lyrics, the queue and the comments take the place of the right column, and Back closes a panel before the player.
class TvPlayer extends StatefulWidget {
  const TvPlayer({
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

  /// The room at the sides and above and below, and how much of the width the cover has.
  static const margin = 40.0;
  static const vertical = 24.0;

  @override
  State<TvPlayer> createState() => _TvPlayerState();
}

class _TvPlayerState extends State<TvPlayer> {
  /// Holds the row of buttons, to put the focus on the middle of it (Play) when the player opens.
  final _buttons = FocusNode(
    debugLabel: 'tv transport',
    canRequestFocus: false,
    skipTraversal: true,
  );

  // The bar, the buttons and the icons stand in a different place when a panel takes the right column: kept by a key they
  // move there with their focus, and the one who pressed OK on an icon is still on it
  final _barKey = GlobalKey();
  final _transportKey = GlobalKey();
  final _toolbarKey = GlobalKey();

  RoomController get _c => widget.controller;

  /// How long a picture of a video is left alone before the bar and the buttons go away from over it.
  static const _idleAfter = Duration(seconds: 5);

  /// Catches the keys while the controls are away: the first of them brings the controls back and does nothing else.
  final _catcher = FocusNode(debugLabel: 'tv video idle', skipTraversal: true);
  Timer? _idleTimer;
  bool _idle = false;

  bool get _watching =>
      widget.panel == NowPlayingPanel.cover && _c.snapshot.video;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusPlay());
    _arm();
  }

  @override
  void didUpdateWidget(TvPlayer old) {
    super.didUpdateWidget(old);
    if (!_watching) {
      _idleTimer?.cancel();
      _idle = false;
    } else if (_idleTimer == null || !_idleTimer!.isActive) {
      if (!_idle) _arm();
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _catcher.dispose();
    _buttons.dispose();
    super.dispose();
  }

  void _arm() {
    _idleTimer?.cancel();
    if (!_watching) return;
    _idleTimer = Timer(_idleAfter, () {
      if (!mounted || !_watching || !_c.isPlaying) return _arm();
      setState(() => _idle = true);
      _catcher.requestFocus();
    });
  }

  /// A key: with the controls away it brings them back (and is no more than that), otherwise it only keeps them.
  KeyEventResult _wake(FocusNode node, KeyEvent event) {
    if (!_idle) {
      if (event is KeyDownEvent) _arm();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      setState(() => _idle = false);
      _arm();
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusPlay());
    }
    return KeyEventResult.handled;
  }

  /// With keys in use the focus is on Play from the start: what a remote presses first is OK.
  void _focusPlay() {
    if (!mounted || !keysAreInUse) return;
    final nodes = [
      for (final node in _buttons.descendants)
        if (node.canRequestFocus && !node.skipTraversal) node,
    ];
    if (nodes.isEmpty) return;
    final box = _buttons.context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final middle = box.localToGlobal(box.size.center(Offset.zero)).dx;
    nodes.sort(
      (a, b) => (a.rect.center.dx - middle).abs().compareTo(
        (b.rect.center.dx - middle).abs(),
      ),
    );
    nodes.first.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final look = PlayerLookScope.of(context);
    final cover = widget.panel == NowPlayingPanel.cover;
    final video = _c.snapshot.video;
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight;
        // The full-bleed cover stays as it is while a panel is open: the panel takes the right column only
        final full = look.style == PlayerStyle.appleMusic && !video;
        // The cover: as tall as the height leaves it, and no wider than a third of the screen
        final side = math.min(
          340.0,
          math.min(height - 2 * TvPlayer.vertical - 8, box.maxWidth * 0.36),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            // The cover that fills the left half and fades into the page
            if (full)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: box.maxWidth * 0.46,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    colors: [Colors.black, Colors.black, Colors.transparent],
                    stops: [0, 0.6, 1],
                  ).createShader(rect),
                  child: Artwork(
                    url: widget.current.thumb,
                    size: height,
                    width: box.maxWidth * 0.46,
                    radius: 0,
                    sharp: true,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TvPlayer.margin,
                TvPlayer.vertical,
                TvPlayer.margin,
                TvPlayer.vertical,
              ),
              child: video && cover
                  ? _videoLayout(context)
                  : Row(
                      children: [
                        SizedBox(
                          width: full
                              ? box.maxWidth * 0.46 - TvPlayer.margin
                              : side,
                          child: full
                              ? null
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    PlayerCoverArt(
                                      controller: _c,
                                      current: widget.current,
                                      size: side,
                                    ),
                                  ],
                                ),
                        ),
                        const SizedBox(width: 40),
                        Expanded(
                          child: cover
                              ? _controls(context, look)
                              : _panel(context, look),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Audio or Video, in the manner of the style.
  Widget _mode(PlayerLook look) => look.style == PlayerStyle.classic
      ? ModePill(controller: _c)
      : ModeToggle(
          controller: _c,
          onPicture: look.style == PlayerStyle.appleMusic,
        );

  /// The song, its bar and its buttons.
  Widget _controls(BuildContext context, PlayerLook look) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      // The card style says what the song is playing from, as its head does on a phone
      look.style == PlayerStyle.spotify
          ? Row(
              children: [
                Expanded(
                  child: PlayingFromLine(
                    controller: _c,
                    current: widget.current,
                    textAlign: TextAlign.left,
                  ),
                ),
                _mode(look),
              ],
            )
          : Align(alignment: Alignment.centerRight, child: _mode(look)),
      const Spacer(),
      PlayerTitleRow(controller: _c, current: widget.current, wrapLines: 2),
      const SizedBox(height: 16),
      PlaybackBar(key: _barKey, controller: _c),
      const SizedBox(height: 12),
      Focus(
        focusNode: _buttons,
        includeSemantics: false,
        child: TransportRow(key: _transportKey, controller: _c),
      ),
      const SizedBox(height: 12),
      _toolbar(look),
      if (_c.snapshot.inRoom) ...[
        const SizedBox(height: 6),
        RoomStrip(controller: _c),
      ],
      const Spacer(),
    ],
  );

  /// The row of icons. Lyrics are a button here in every style: there is no card for them to be in.
  Widget _toolbar(PlayerLook look) => PlayerToolbar(
    key: _toolbarKey,
    controller: _c,
    panel: widget.panel,
    onPanel: widget.onPanel,
    kind: look.toolbar == ToolbarKind.face ? ToolbarKind.classic : null,
  );

  /// Lyrics, the queue or the comments, in the place of the song's column; the bar and the buttons stay under it.
  Widget _panel(BuildContext context, PlayerLook look) => Column(
    children: [
      Expanded(
        child: PlayerPanelStage(
          controller: _c,
          current: widget.current,
          panel: widget.panel,
          onCover: () => widget.onChoose(NowPlayingPanel.cover),
          compact: true,
        ),
      ),
      const SizedBox(height: 8),
      PlaybackBar(key: _barKey, controller: _c, compact: true),
      Focus(
        focusNode: _buttons,
        includeSemantics: false,
        child: TransportRow(key: _transportKey, controller: _c, playSize: 56),
      ),
      _toolbar(look),
    ],
  );

  /// The picture of a song shown as a video: the whole screen, with the bar and the buttons over its foot, which go away
  /// after a few seconds and come back with any key.
  Widget _videoLayout(BuildContext context) {
    final look = PlayerLookScope.of(context);
    return Focus(
      focusNode: _catcher,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _wake,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: _wake,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: PlayerCoverArt(
                  controller: _c,
                  current: widget.current,
                  size: 400,
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: _idle ? 0 : 1,
              duration: Motion.of(context, 250),
              child: ExcludeFocus(
                excluding: _idle,
                child: IgnorePointer(
                  ignoring: _idle,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [_mode(look)],
                      ),
                      const Spacer(),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                        ),
                        child: Column(
                          children: [
                            PlaybackBar(
                              key: _barKey,
                              controller: _c,
                              compact: true,
                            ),
                            Focus(
                              focusNode: _buttons,
                              includeSemantics: false,
                              child: TransportRow(
                                key: _transportKey,
                                controller: _c,
                                playSize: 56,
                              ),
                            ),
                            _toolbar(look),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
