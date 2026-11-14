import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../format.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import '../player/track_section.dart';
import '../scope.dart';
import 'artwork.dart';
import 'meta_line.dart';
import 'not_interested.dart';

/// A cover with two lines under it, and a third for a count of views when there is one, for a row that scrolls sideways.
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
    this.meta,
  });

  /// A card for an album or a playlist: YouTube writes the views of a playlist after its maker ("Anna • 2.2M views"),
  /// and the count goes to a line of its own, in the language of the app.
  factory SongCard.listing({
    Key? key,
    required String title,
    required String? subtitle,
    required String? thumb,
    required VoidCallback onTap,
  }) {
    final split = splitViews(subtitle);
    return SongCard(
      key: key,
      title: title,
      subtitle: split.views == null ? subtitle ?? '' : split.text,
      meta: split.views,
      thumb: thumb,
      onTap: onTap,
    );
  }

  /// A card for a song; holding it down asks whether the person is interested in it. A [video] has a wide cover.
  /// The count is the one the song's list gave, or one shown for it earlier.
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
    meta: AppScope.of(context).music.viewsFor(track),
  );

  final String title;
  final String subtitle;
  final String? thumb;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// How many watched or played it ("2.3M plays"), on a line under the artist; left out when it does not fit whole.
  final String? meta;

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
            if (meta != null)
              MetaLine(text: '', meta: meta, style: theme.bodySmall?.copyWith(color: p.textSecondary)),
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
    // The line for a count is made once for the whole shelf, from what its cards hold, so that its height is the same
    // from the first frame and the cards stand level whether they have a count or not
    final counted = cards.any((c) => c is SongCard && c.meta != null);
    final line = counted ? MediaQuery.textScalerOf(context).scale(18) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title),
        SizedBox(
          // The cover and its two lines, and a third when a card has a count
          height: video
              ? SongCard.videoWidth(HomeShell.cardSizeOf(context)) * 9 / 16 + 60 + line
              : HomeShell.cardSizeOf(context) + 60 + line,
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
