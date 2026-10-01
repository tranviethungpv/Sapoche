import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'glass.dart';

/// Play or pause glyph that morphs between the two, with a spinner while the room is starting.
class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({
    super.key,
    required this.playing,
    required this.starting,
    required this.onPressed,
    this.size = 72,
    this.filled = true,
  });

  final bool playing;
  final bool starting;
  final VoidCallback onPressed;
  final double size;

  /// Filled pink disc (full player) or bare glyph (mini player).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glyphColor = filled ? p.onPrimary : p.text;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: filled
            ? GlassDecoration.of(
                p,
                radius: size,
                tint: p.primary,
                solid: true,
                floating: true,
              )
            : const BoxDecoration(),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(playing),
                    size: size * 0.56,
                    color: glyphColor,
                  ),
                ),
                if (starting)
                  SizedBox.square(
                    dimension: size * 0.86,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: filled
                          ? p.onPrimary.withValues(alpha: 0.7)
                          : p.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Previous or next: a plain glyph with a generous tap target.
class SkipButton extends StatelessWidget {
  const SkipButton({
    super.key,
    required this.forward,
    required this.onPressed,
    this.size = 44,
  });

  final bool forward;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      iconSize: size,
      icon: Icon(
        forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
      ),
      color: context.palette.text,
    );
  }
}
