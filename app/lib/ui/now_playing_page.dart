import 'dart:ui';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/playback_bar.dart';
import 'widgets/transport.dart';
import 'widgets/wash.dart';

/// Opens the full player as a sheet that slides up over the current screen.
void openNowPlaying(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, _, _) => const NowPlayingPage(),
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: Tween(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
            child: child,
          ),
    ),
  );
}

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    return GestureDetector(
      // A downward fling closes the sheet
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 700) Navigator.of(context).maybePop();
      },
      child: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final current = controller.snapshot.current;
            if (current == null) {
              // The queue emptied while the sheet was open
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).maybePop();
              });
              return const SizedBox.shrink();
            }
            return _Body(controller: controller, current: current);
          },
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    // Everything except the cover needs about this much height; the cover takes what is left
    const otherContent = 350.0;
    final artSize = [
      size.width - 64,
      380.0,
      size.height - padding.vertical - otherContent,
    ].reduce((a, b) => a < b ? a : b).clamp(140.0, 380.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // The cover's own colours, blurred, tint the pink veil differently for every song
        ColoredBox(color: p.base),
        if (current.thumb != null)
          Opacity(
            opacity: p.brightness == Brightness.dark ? 0.5 : 0.35,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 70,
                sigmaY: 70,
                tileMode: TileMode.decal,
              ),
              child: Image.network(
                current.thumb!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
          ),
        const PinkWash(intensity: 0.85, child: SizedBox.expand()),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const SizedBox(height: 6),
                _Grabber(color: p.textTertiary.withValues(alpha: 0.5)),
                const Spacer(flex: 2),
                ListenableBuilder(
                  listenable: controller.player,
                  builder: (context, _) => AnimatedScale(
                    // Paused covers shrink, like in Apple Music
                    scale: controller.isPlaying ? 1 : 0.86,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutBack,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: controller.isPlaying ? 0.28 : 0.14,
                            ),
                            blurRadius: controller.isPlaying ? 36 : 18,
                            offset: Offset(0, controller.isPlaying ? 18 : 8),
                          ),
                        ],
                      ),
                      child: Hero(
                        tag: 'artwork',
                        child: Artwork(
                          url: current.thumb,
                          size: artSize,
                          radius: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(flex: 2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.headlineSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        current.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.titleMedium?.copyWith(
                          color: p.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                PlaybackBar(controller: controller),
                const SizedBox(height: 10),
                ListenableBuilder(
                  listenable: controller.player,
                  builder: (context, _) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SkipButton(
                        forward: false,
                        onPressed: controller.prev,
                        size: 52,
                      ),
                      PlayPauseButton(
                        playing: controller.isPlaying,
                        starting: controller.isStarting,
                        onPressed: controller.togglePlay,
                      ),
                      SkipButton(
                        forward: true,
                        onPressed: controller.next,
                        size: 52,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                _RoomStrip(controller: controller),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
      ],
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

/// Who is listening and whether this phone is in step with them.
class _RoomStrip extends StatelessWidget {
  const _RoomStrip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final snapshot = controller.snapshot;
    return Row(
      children: [
        AvatarStack(members: snapshot.members, size: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            S.listening(snapshot.members.length),
            style: theme.bodySmall?.copyWith(color: p.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ListenableBuilder(
          listenable: controller.player,
          builder: (context, _) => _SyncChip(controller: controller),
        ),
      ],
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final player = controller.player.value;
    final drift = player.driftMs;
    final String label;
    final Color color;
    if (!controller.isPlaying) {
      return const SizedBox.shrink();
    } else if (controller.isStarting) {
      label = S.buffering;
      color = p.textSecondary;
    } else if (drift == null) {
      label = S.syncing;
      color = p.textSecondary;
    } else {
      label = '${S.inSync} · ${formatDrift(drift)}';
      color = drift.abs() <= 60 ? p.success : p.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
