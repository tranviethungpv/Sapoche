import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../theme/theme.dart';
import '../now_playing_page.dart';
import 'artwork.dart';
import 'glass.dart';
import 'transport.dart';

/// Floating capsule above the tab bar. Tap it to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller});

  final RoomController controller;

  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.snapshot.current;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.6),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: current == null
              ? const SizedBox(key: ValueKey('none'), width: double.infinity)
              : Padding(
                  key: const ValueKey('player'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Glass(
                    borderRadius: BorderRadius.circular(22),
                    border: true,
                    child: InkWell(
                      onTap: () => openNowPlaying(context),
                      child: SizedBox(
                        height: height,
                        child: Row(
                          children: [
                            const SizedBox(width: 10),
                            Hero(
                              tag: 'artwork',
                              child: Artwork(
                                url: current.thumb,
                                size: 44,
                                radius: 8,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    current.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.titleSmall,
                                  ),
                                  Text(
                                    current.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.bodySmall?.copyWith(
                                      color: p.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ListenableBuilder(
                              listenable: controller.player,
                              builder: (context, _) => PlayPauseButton(
                                playing: controller.isPlaying,
                                starting: controller.isStarting,
                                onPressed: controller.togglePlay,
                                size: 48,
                                filled: false,
                              ),
                            ),
                            SkipButton(
                              forward: true,
                              onPressed: controller.next,
                              size: 34,
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
