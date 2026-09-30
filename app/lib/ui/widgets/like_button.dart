import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';

/// A heart that keeps the song in the liked songs, and lights up when it is there.
class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.track, this.size = 24});

  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final p = context.palette;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final liked = library.isLiked(track.videoId);
        return IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            library.toggleLike(track);
          },
          tooltip: liked ? S.unlike : S.like,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(
            width: size + 16,
            height: size + 16,
          ),
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(liked),
              size: size,
              color: liked ? p.primary : p.textTertiary,
            ),
          ),
        );
      },
    );
  }
}
