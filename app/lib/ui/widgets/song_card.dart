import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/theme.dart';
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
    this.size = 148,
  });

  /// A card for a song; holding it down asks whether the person is interested in it.
  factory SongCard.track(
    BuildContext context,
    Track track, {
    required VoidCallback onTap,
  }) => SongCard(
    title: track.title,
    subtitle: track.artist,
    thumb: track.thumb,
    onTap: onTap,
    onLongPress: () => showNotInterested(context, track),
  );

  final String title;
  final String subtitle;
  final String? thumb;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Artwork(url: thumb, size: size, radius: 12),
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
  const CardShelf({super.key, required this.title, required this.cards});

  final String title;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title),
        SizedBox(
          height: 208,
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
