import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import '../player/track_section.dart';
import 'artwork.dart';
import 'not_interested.dart';

/// A cover with two lines under it, for a row that scrolls sideways.
class SongCard extends StatelessWidget {
  const SongCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumb,
    required this.onTap,
    this.onLongPress,
    this.size,
    this.video = false,
  });

  /// A card for a song; holding it down asks whether the person is interested in it. A [video] has a wide cover.
  factory SongCard.track(
    BuildContext context,
    Track track, {
    required VoidCallback onTap,
    bool video = false,
  }) => SongCard(
    title: track.title,
    subtitle: track.artist,
    thumb: track.thumb,
    onTap: onTap,
    onLongPress: () => showNotInterested(context, track),
    video: video,
  );

  final String title;
  final String subtitle;
  final String? thumb;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Side of the cover; by default the one that suits the window.
  final double? size;

  /// The cover is 16:9, as a video's is, and wider than a square one is tall (see [videoWidth]).
  final bool video;

  /// How wide a video's cover is, for a square one of side [side]: more than a square, less than 16:9 at that height, so
  /// that the next card still peeks in from the edge.
  static double videoWidth(double side) => side * 1.5;

  @override
  Widget build(BuildContext context) {
    final size = this.size ?? HomeShell.cardSizeOf(context);
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    // An InkWell, so that a remote's arrows and a keyboard's Tab can reach it, and a mouse lights it up
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: video ? videoWidth(size) : size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            video
                ? Artwork(
                    url: thumb,
                    width: videoWidth(size),
                    size: videoWidth(size) * 9 / 16,
                    radius: 12,
                  )
                : Artwork(url: thumb, size: size, radius: 12),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.titleSmall,
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.bodySmall?.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A heading and a row of [SongCard]s that scrolls sideways.
class CardShelf extends StatelessWidget {
  const CardShelf({
    super.key,
    required this.title,
    required this.cards,
    this.video = false,
  });

  final String title;
  final List<Widget> cards;

  /// The cards are videos': their covers are wide and short.
  final bool video;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title),
        SizedBox(
          // The cover and its two lines
          height: video
              ? SongCard.videoWidth(HomeShell.cardSizeOf(context)) * 9 / 16 + 60
              : HomeShell.cardSizeOf(context) + 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, i) => cards[i],
          ),
        ),
      ],
    );
  }
}
