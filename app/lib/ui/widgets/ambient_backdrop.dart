import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../scope.dart';
import 'player_backdrop.dart';
import 'wash.dart';

/// The backdrop of the pages that are not about one album or artist (home, search, library, settings): the colours
/// of the song that is playing, as the full player shows them but fading into the plain background down the page.
/// The glass bars and everything see-through on the page take those colours, as they take a cover's on an album
/// page, so the whole app is lit by the one song. With nothing playing it is the pink veil.
///
/// It is the same picture as the player's, made once per song, so it costs no more than the veil did.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final p = context.palette;
    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: room,
          builder: (context, _) {
            final cover = room.snapshot.current?.thumb;
            if (cover == null) return const PinkWash(child: SizedBox.expand());
            return Stack(
              fit: StackFit.expand,
              children: [
                PlayerBackdrop(coverUrl: cover),
                // Strongest at the top, behind the titles, and mostly gone by the bottom
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.55, 1],
                      colors: [
                        p.base.withValues(alpha: 0),
                        p.base.withValues(alpha: 0.45),
                        p.base.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        child,
      ],
    );
  }
}
