import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../scope.dart';
import 'player_backdrop.dart';
import 'wash.dart';

/// The backdrop of the pages that are not about one album or artist (home, search, library, settings): the plain
/// background of the app with a glow along the top in the colours of the song that is playing, which thins out
/// by two fifths of the way down. Only the top is lit, as only the one thing is what a page is about; what scrolls
/// under the glass bars keeps its own colours. With nothing playing it is the pink veil.
///
/// It is the same picture as the player's, made once per song, so it costs no more than the veil did.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child});

  final Widget child;

  /// How far down the page the glow reaches.
  static const glowHeight = 0.4;

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final p = context.palette;
    return ColoredBox(
      color: p.base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ListenableBuilder(
            listenable: room,
            builder: (context, _) {
              final cover = room.snapshot.current?.thumb;
              if (cover == null) {
                return const PinkWash(opaque: false, child: SizedBox.expand());
              }
              return PlayerBackdrop(coverUrl: cover, glowHeight: glowHeight);
            },
          ),
          child,
        ],
      ),
    );
  }
}
