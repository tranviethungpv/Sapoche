import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../scope.dart';
import 'player_backdrop.dart';
import 'wash.dart';

/// The backdrop of the pages that are not about one album or artist (home, search, library, settings): the plain
/// background of the app with a glow along the top in the colours of the song that is playing, which thins out
/// by a third of the way down. Only the top is lit, as only the one thing is what a page is about; what scrolls
/// under the glass bars keeps its own colours. With nothing playing it is the pink veil.
///
/// It is the same picture as the player's, made once per song, so it costs no more than the veil did.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child})
    : cover = null,
      ownCover = false;

  /// The backdrop of a page that is about one cover (an album, a playlist, an artist): the same glow, in the colours
  /// of [cover] instead of the song that is playing. With no cover, as while it is being found, it is the pink veil.
  const AmbientBackdrop.cover({
    super.key,
    required this.cover,
    required this.child,
  }) : ownCover = true;

  final Widget child;
  final String? cover;
  final bool ownCover;

  /// How far down the page the glow reaches.
  static const glowHeight = 0.34;

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final p = context.palette;
    return ColoredBox(
      color: p.base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ownCover)
            _glow(cover)
          else
            ListenableBuilder(
              listenable: room,
              builder: (context, _) => _glow(room.snapshot.current?.thumb),
            ),
          child,
        ],
      ),
    );
  }

  static Widget _glow(String? cover) => cover == null
      ? const PinkWash(opaque: false, child: SizedBox.expand())
      : PlayerBackdrop(coverUrl: cover, glowHeight: glowHeight);
}
