import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import '../player_sheet.dart';
import 'artwork.dart';
import 'glass.dart';
import 'low_rate_timer.dart';
import 'marquee_text.dart';
import 'transport.dart';

/// Floating capsule above the tab bar. Tap it, or drag it up, to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller, this.folded = 0});

  final RoomController controller;

  /// How far the bars are folded away, 0 to 1. Folded, the capsule sits between the tab that is open and Search, as
  /// low as they are and as high, with the cover, the title and the play button only.
  final double folded;

  /// Lower on a screen that is wider than it is tall, where height is what is short, and always lower than the tabs
  /// under it on a phone. A tablet's, which floats alone, is a little lower than a phone's was.
  static double heightOf(BuildContext context) =>
      switch (HomeShell.layoutOf(context)) {
        ShellLayout.bars => HomeShell.isWide(context) ? 40 : 46,
        // On its side a phone has little height; a tablet's is a little lower than a phone's was
        ShellLayout.rail when HomeShell.compactOf(context) => 40,
        _ => HomeShell.isWide(context) ? 48 : 54,
      };

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.snapshot.current;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          // A new list empties the queue and fills it again at once: the capsule that was leaving is dropped as the
          // new one comes, as the two cannot share the keys the opening player finds the capsule and its cover by
          layoutBuilder: (shown, leaving) => Stack(
            alignment: Alignment.center,
            children: [if (current == null) ...leaving, ?shown],
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.6),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: current == null
              ? const SizedBox(key: ValueKey('none'), width: double.infinity)
              : PlayerOpenDrag(
                  key: const ValueKey('player'),
                  child: KeyedSubtree(
                    key: sheet.miniBar,
                    child: MiniPlayerCapsule(
                      controller: controller,
                      onTap: sheet.open,
                      folded: folded,
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The capsule itself. With [ghost] it is only a picture of the capsule, drawn by the opening player as the capsule
/// turns into it: it takes no touches and leaves the cover to the cover that flies.
class MiniPlayerCapsule extends StatelessWidget {
  const MiniPlayerCapsule({
    super.key,
    required this.controller,
    this.onTap,
    this.ghost = false,
    this.folded = 0,
  });

  final RoomController controller;
  final VoidCallback? onTap;
  final bool ghost;

  /// See [MiniPlayer.folded].
  final double folded;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sheet = PlayerSheetScope.of(context);
    final current = controller.snapshot.current;
    if (current == null) return const SizedBox.shrink();
    final height = MiniPlayer.heightOf(context);
    final cover = (height - 8).clamp(0.0, 44.0);
    // The play button and the next one are the same size and on the same line
    final button = height < 48 ? height : 48.0;
    // What folding takes away is gone half way
    final fading = (1 - 2 * folded).clamp(0.0, 1.0);
    return Glass(
      borderRadius: BorderRadius.circular(height / 2),
      child: Stack(
        children: [
          InkWell(
            onTap: onTap,
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  // The cover is round and as far from the edge on the left as from the top and bottom, so its curve
                  // follows the capsule's end
                  SizedBox(width: (height - cover) / 2),
                  if (ghost)
                    SizedBox.square(dimension: cover)
                  else
                    Artwork(
                      key: sheet.miniCover,
                      url: current.thumb,
                      size: cover,
                      radius: cover / 2,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarqueeText(
                          current.title,
                          style: theme.titleSmall,
                          rounds: MarqueeText.barRounds,
                        ),
                        if (fading > 0)
                          Align(
                            alignment: Alignment.topLeft,
                            heightFactor: 1 - folded,
                            child: Opacity(
                              opacity: fading,
                              child: MarqueeText(
                                controller.snapshot.solo
                                    ? '${current.artist} · ${S.onYourOwn}'
                                    : current.artist,
                                style: theme.bodySmall?.copyWith(
                                  color: p.textSecondary,
                                ),
                                rounds: MarqueeText.barRounds,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListenableBuilder(
                    listenable: controller.playState,
                    builder: (context, _) => PlayPauseButton(
                      playing: controller.isPlaying,
                      starting: controller.isStarting,
                      onPressed: controller.togglePlay,
                      size: button,
                      filled: false,
                    ),
                  ),
                  if (fading > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1 - folded,
                      child: Opacity(
                        opacity: fading,
                        child: SkipButton(
                          forward: true,
                          onPressed: controller.next,
                          box: button,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          // How far the song has gone, along the lower edge of the capsule, as Spotify's and YouTube Music's have it
          if (!ghost)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 2,
              child: IgnorePointer(
                child: _MiniProgress(controller: controller),
              ),
            ),
        ],
      ),
    );
  }
}

/// A thin line of the song's progress. It is drawn again once a second, in a layer of its own, not at the pace of the
/// bar of the full player: it sits over glass, which is costly to draw again, and a second is as fine as a line this
/// short can show.
class _MiniProgress extends StatefulWidget {
  const _MiniProgress({required this.controller});

  final RoomController controller;

  @override
  State<_MiniProgress> createState() => _MiniProgressState();
}

class _MiniProgressState extends State<_MiniProgress> {
  late final LowRateTimer _ticker = LowRateTimer(
    const Duration(seconds: 1),
    () => setState(() {}),
  );

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.player.addListener(_sync);
    _c.addListener(_sync);
    _ticker.run(_c.player.value.playing);
  }

  void _sync() {
    _ticker.run(_c.player.value.playing);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.player.removeListener(_sync);
    _c.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = _c.durationMs();
    final fraction = duration > 0
        ? (_c.positionMs() / duration).clamp(0.0, 1.0)
        : 0.0;
    return RepaintBoundary(
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction,
          heightFactor: 1,
          child: ColoredBox(color: context.palette.primary),
        ),
      ),
    );
  }
}
