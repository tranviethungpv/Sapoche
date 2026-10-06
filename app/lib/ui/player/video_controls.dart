import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../widgets/like_button.dart';
import '../widgets/playback_bar.dart';
import '../widgets/video_view.dart';

/// The heights the picture can be fetched at, the tallest first offered last.
const videoQualities = [360, 480, 720, 1080];

/// The speeds a song can be played at outside a room.
const playbackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// How far a double tap, or a touch on the buttons beside play, moves the song.
const _skipMs = 10000;

/// How long the controls stay after the last touch while the song plays. Paused, they stay.
const _controlsLinger = Duration(seconds: 3);

/// Two taps closer than this on the same side are a double tap.
const _doubleTapWindow = Duration(milliseconds: 300);

/// After a double tap, every tap on the same side within this long moves the song again, like YouTube.
const _burstWindow = Duration(milliseconds: 800);

/// The controls over the picture, as video apps have them: a touch shows or hides them, and they hide by themselves
/// while the song plays. A double tap on the left or the right goes back or forward ten seconds, and more taps on the
/// same side right after go further. In the player they sit inside the picture's frame; [fullScreen], across the
/// whole screen with the song's name, a seek bar and the way back.
class VideoControls extends StatefulWidget {
  const VideoControls({
    super.key,
    required this.controller,
    this.fullScreen = false,
    this.fill = false,
    this.onFill,
  });

  final RoomController controller;
  final bool fullScreen;

  /// Full screen: the picture fills the screen, cropped, rather than fitting into it.
  final bool fill;

  /// Full screen: two fingers pinched open ([fill] true) or closed, or the button pressed.
  final ValueChanged<bool>? onFill;

  @override
  State<VideoControls> createState() => VideoControlsState();
}

class VideoControlsState extends State<VideoControls> {
  /// Shown at first in the full screen, and over a paused song, where play should be at hand.
  late bool _shown = widget.fullScreen || !widget.controller.isPlaying;
  Timer? _hideTimer;

  /// The side of the first tap of a possible double tap, while its window is open.
  int? _tapSide;
  Timer? _tapTimer;

  /// Whether the controls were shown before that first tap, as the second one takes its toggle back.
  bool _shownBeforeTap = false;

  /// While taps keep moving the song: the side (-1 back, 1 forward) and the seconds moved so far.
  int _burstSide = 0;
  int _burstSeconds = 0;
  Timer? _burstTimer;

  /// Full screen: how far one finger has pulled the picture down, to leave, and how far two have pinched.
  double _pull = 0;
  double _pinch = 1;

  RoomController get _c => widget.controller;

  /// Whether the controls are showing; for tests.
  bool get shown => _shown;

  @override
  void initState() {
    super.initState();
    _c.playState.addListener(_playStateChanged);
    _armHide();
  }

  @override
  void dispose() {
    _c.playState.removeListener(_playStateChanged);
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _burstTimer?.cancel();
    super.dispose();
  }

  void _playStateChanged() {
    // Paused, the controls stay where the person can reach play; playing again, they go after a while
    if (_c.isPlaying) {
      _armHide();
    } else {
      _hideTimer?.cancel();
      if (!_shown && mounted) setState(() => _shown = true);
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_shown || !_c.isPlaying) return;
    _hideTimer = Timer(_controlsLinger, () {
      if (mounted) setState(() => _shown = false);
    });
  }

  void _setShown(bool shown) {
    setState(() => _shown = shown);
    _armHide();
  }

  /// A button was used: the controls stay a while longer.
  void _touched(VoidCallback action) {
    action();
    _armHide();
  }

  /// -1 for the left third, 1 for the right third, 0 in the middle, where a double tap does nothing.
  static int _sideOf(double x, double width) =>
      x < width / 3 ? -1 : (x > width * 2 / 3 ? 1 : 0);

  void _tapped(TapUpDetails details, double width) {
    final side = _sideOf(details.localPosition.dx, width);
    // Moving the song already: each tap on that side moves it again
    if (_burstSide != 0 && side == _burstSide) {
      _skip(side);
      return;
    }
    // The second tap of a double tap takes back what the first one did to the controls, and moves the song
    if (_tapSide != null && side == _tapSide && side != 0) {
      _tapTimer?.cancel();
      _tapSide = null;
      setState(() => _shown = _shownBeforeTap);
      _armHide();
      _skip(side);
      return;
    }
    // A single tap shows or hides the controls at once, rather than after waiting to see whether a second comes
    _tapTimer?.cancel();
    _tapSide = side;
    _shownBeforeTap = _shown;
    _tapTimer = Timer(_doubleTapWindow, () => _tapSide = null);
    _setShown(!_shown);
  }

  /// Moves the song back ([side] -1) or forward ten seconds, never before the start or past the end.
  void _seekBy(int side) {
    final duration = _c.durationMs();
    final target = _c.positionMs() + side * _skipMs;
    _c.seek(
      duration > 0 ? target.clamp(0, duration) : (target < 0 ? 0 : target),
    );
  }

  /// A double tap's ten seconds, with a note of how far the taps went.
  void _skip(int side) {
    _seekBy(side);
    _burstTimer?.cancel();
    setState(() {
      _burstSeconds =
          (_burstSide == side ? _burstSeconds : 0) + _skipMs ~/ 1000;
      _burstSide = side;
    });
    _burstTimer = Timer(_burstWindow, () {
      if (mounted) setState(() => _burstSide = 0);
    });
  }

  // Full screen: one finger pulls the picture down to leave, two pinch it to fill the screen or fit into it

  void _scaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) {
      _pinch = details.scale;
    } else {
      _pull += details.focalPointDelta.dy;
    }
  }

  void _scaleEnd(ScaleEndDetails details) {
    final pinch = _pinch;
    final pull = _pull;
    _pinch = 1;
    _pull = 0;
    if (pinch != 1) {
      if (pinch > 1.15 && !widget.fill) widget.onFill?.call(true);
      if (pinch < 0.87 && widget.fill) widget.onFill?.call(false);
      return;
    }
    if (pull > 120 ||
        (details.velocity.pixelsPerSecond.dy > 900 && pull > 30)) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.fullScreen;
    return LayoutBuilder(
      builder: (context, box) {
        final Widget surface = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tapped(d, box.maxWidth),
        );
        // Full screen, pinching and pulling down work over the buttons too: they win once the fingers move
        return GestureDetector(
          onScaleUpdate: full ? _scaleUpdate : null,
          onScaleEnd: full ? _scaleEnd : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              surface,
              IgnorePointer(
                child: _SkipNote(side: _burstSide, seconds: _burstSeconds),
              ),
              IgnorePointer(
                ignoring: !_shown,
                child: AnimatedOpacity(
                  opacity: _shown ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: full
                      ? _fullControls(context)
                      : _inlineControls(context, box),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _inlineControls(BuildContext context, BoxConstraints box) {
    // A small picture (the player on its side, a short phone) gets smaller buttons rather than crowded ones
    final small = box.maxWidth < 240 || box.maxHeight < 150;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Touches go through the shade to the picture, which shows and hides the controls
        const IgnorePointer(child: ColoredBox(color: Color(0x59000000))),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _centerRow(big: small ? 48 : 60, side: small ? 30 : 36),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_c.pipSupported)
                _icon(
                  Icons.picture_in_picture_alt_rounded,
                  S.pictureInPicture,
                  _c.enterPictureInPicture,
                ),
              _icon(
                Icons.settings_rounded,
                S.videoSettings,
                () => showVideoSettings(context, _c),
              ),
            ],
          ),
        ),
        Positioned(
          right: 2,
          bottom: 2,
          child: _icon(
            Icons.fullscreen_rounded,
            S.fullScreen,
            () => openVideoFullScreen(context, _c),
            size: 28,
          ),
        ),
      ],
    );
  }

  Widget _fullControls(BuildContext context) {
    final current = _c.snapshot.current;
    final theme = Theme.of(context).textTheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Darker at the top and the bottom, where the words and the bar are
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xA6000000),
                  Color(0x40000000),
                  Color(0x40000000),
                  Color(0xB3000000),
                ],
                stops: [0, 0.3, 0.7, 1],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              children: [
                Row(
                  children: [
                    _icon(
                      Icons.keyboard_arrow_down_rounded,
                      S.exitFullScreen,
                      () => Navigator.of(context).maybePop(),
                      size: 32,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            current?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.titleMedium?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            current?.artist ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (current != null) LikeButton(track: current, size: 24),
                    if (_c.pipSupported)
                      _icon(
                        Icons.picture_in_picture_alt_rounded,
                        S.pictureInPicture,
                        _c.enterPictureInPicture,
                      ),
                    _icon(
                      Icons.settings_rounded,
                      S.videoSettings,
                      () => showVideoSettings(context, _c),
                    ),
                  ],
                ),
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _centerRow(big: 68, side: 40, skips: true),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: PlaybackBar(controller: _c),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _icon(
                      widget.fill
                          ? Icons.fit_screen_rounded
                          : Icons.crop_free_rounded,
                      widget.fill ? S.fitScreen : S.fillScreen,
                      () => widget.onFill?.call(!widget.fill),
                    ),
                    _icon(
                      Icons.fullscreen_exit_rounded,
                      S.exitFullScreen,
                      () => Navigator.of(context).maybePop(),
                      size: 28,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Back ten seconds, play or pause, forward ten seconds; full screen, with previous and next around them.
  Widget _centerRow({
    required double big,
    required double side,
    bool skips = false,
  }) => ListenableBuilder(
    listenable: _c.playState,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (skips) ...[
          _icon(
            Icons.skip_previous_rounded,
            S.previousSong,
            _c.prev,
            size: side,
          ),
          SizedBox(width: side * 0.4),
        ],
        _icon(Icons.replay_10_rounded, S.back10, () => _seekBy(-1), size: side),
        SizedBox(width: side * 0.6),
        SizedBox.square(
          dimension: big,
          child: _c.isStarting
              ? Padding(
                  padding: EdgeInsets.all(big * 0.2),
                  child: const CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                )
              : IconButton(
                  onPressed: () => _touched(_c.togglePlay),
                  tooltip: _c.isPlaying ? S.pause : S.play,
                  iconSize: big * 0.8,
                  color: Colors.white,
                  icon: Icon(
                    _c.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
        ),
        SizedBox(width: side * 0.6),
        _icon(
          Icons.forward_10_rounded,
          S.forward10,
          () => _seekBy(1),
          size: side,
        ),
        if (skips) ...[
          SizedBox(width: side * 0.4),
          _icon(Icons.skip_next_rounded, S.nextSong, _c.next, size: side),
        ],
      ],
    ),
  );

  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    double size = 24,
  }) => IconButton(
    onPressed: () => _touched(onPressed),
    tooltip: tooltip,
    iconSize: size,
    color: Colors.white,
    icon: Icon(icon),
  );
}

/// "10 seconds" on the side a double tap moved the song to, with the arrows of that way.
class _SkipNote extends StatelessWidget {
  const _SkipNote({required this.side, required this.seconds});

  final int side;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: side == 0 ? 0 : 1,
      duration: const Duration(milliseconds: 150),
      child: side == 0
          ? const SizedBox.expand()
          : Align(
              alignment: side < 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 0.38,
                heightFactor: 1,
                child: DecoratedBox(
                  key: ValueKey('skip-note-$side'),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: side < 0
                        ? const BorderRadius.horizontal(
                            right: Radius.circular(400),
                          )
                        : const BorderRadius.horizontal(
                            left: Radius.circular(400),
                          ),
                  ),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            side < 0
                                ? Icons.fast_rewind_rounded
                                : Icons.fast_forward_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                          Text(
                            S.seconds(seconds),
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// The picture across the whole screen, shown by [openVideoFullScreen].
class VideoFullScreen extends StatefulWidget {
  const VideoFullScreen({
    super.key,
    required this.controller,
    required this.turned,
  });

  final RoomController controller;

  /// Opened by turning the phone on its side: turning it upright again closes it, and the screen is free to turn.
  final bool turned;

  /// A full screen picture is showing. The player does not open another when the phone turns under it.
  static final ValueNotifier<bool> open = ValueNotifier(false);

  @override
  State<VideoFullScreen> createState() => _VideoFullScreenState();
}

class _VideoFullScreenState extends State<VideoFullScreen> {
  bool _fill = false;
  bool _leaving = false;

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_roomChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Turned on its side to open, turned upright to close
    if (widget.turned &&
        MediaQuery.orientationOf(context) == Orientation.portrait) {
      _leave();
    }
  }

  @override
  void dispose() {
    _c.removeListener(_roomChanged);
    super.dispose();
  }

  /// Nothing to show any more: the queue ran out, or the person went back to sound only on another screen.
  void _roomChanged() {
    if (_c.snapshot.current == null || !_c.snapshot.video) {
      _leave();
    } else if (!_leaving) {
      setState(() {}); // another song: its name
    }
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _c.snapshot.current;
    return Theme(
      data: buildTheme(Palette.dark),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: current == null
              ? const SizedBox.expand()
              : VideoView(
                  key: const ValueKey('full-screen-video'),
                  controller: _c,
                  cover: current,
                  fit: _fill ? BoxFit.cover : BoxFit.contain,
                  overlay: VideoControls(
                    controller: _c,
                    fullScreen: true,
                    fill: _fill,
                    onFill: (fill) => setState(() => _fill = fill),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shows the picture across the whole screen, with the system's bars out of the way. On a phone a wide picture turns
/// the screen on its side and an upright one keeps it upright, as video apps do; [turned] says the phone was turned on
/// its side to get here, so the screen stays free to turn back. Returns once the full screen is left.
Future<void> openVideoFullScreen(
  BuildContext context,
  RoomController controller, {
  bool turned = false,
}) async {
  if (VideoFullScreen.open.value) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final phone = MediaQuery.sizeOf(context).shortestSide < 600;
  final picture = controller.player.value;
  final upright =
      picture.videoWidth > 0 && picture.videoHeight > picture.videoWidth;
  VideoFullScreen.open.value = true;
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (phone && !turned) {
      await SystemChrome.setPreferredOrientations(
        upright
            ? const [DeviceOrientation.portraitUp]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ],
      );
    }
    await navigator.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (context, _, _) =>
            VideoFullScreen(controller: controller, turned: turned),
        transitionsBuilder: (context, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  } finally {
    // The screen turns freely again, and the system's bars come back
    VideoFullScreen.open.value = false;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
  }
}

/// The picture's quality and, outside a room, the speed the song plays at.
Future<void> showVideoSettings(
  BuildContext context,
  RoomController controller,
) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _VideoSettings(controller: controller),
);

class _VideoSettings extends StatelessWidget {
  const _VideoSettings({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(text, style: theme.titleSmall),
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.videoSettings, style: theme.titleLarge),
                heading(S.videoQuality),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final h in videoQualities)
                      ChoiceChip(
                        key: ValueKey('quality-$h'),
                        label: Text('${h}p'),
                        selected: snapshot.videoHeight == h,
                        onSelected: (_) => controller.setVideoQuality(h),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  S.qualityNextSong,
                  style: theme.bodySmall?.copyWith(color: p.textSecondary),
                ),
                heading(S.playbackSpeed),
                if (snapshot.inRoom)
                  Text(
                    S.speedInRoom,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final speed in playbackSpeeds)
                        ChoiceChip(
                          key: ValueKey('speed-$speed'),
                          label: Text(
                            speed == 1
                                ? S.speedNormal
                                : '${_speedLabel(speed)}×',
                          ),
                          selected:
                              (snapshot.playbackSpeed - speed).abs() < 0.01,
                          onSelected: (_) => controller.setPlaybackSpeed(speed),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _speedLabel(double speed) =>
      speed == speed.roundToDouble() ? speed.toStringAsFixed(0) : '$speed';
}
