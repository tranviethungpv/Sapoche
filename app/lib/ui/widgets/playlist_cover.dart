import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'artwork.dart';

/// The cover of a playlist, as YouTube Music draws it: the pictures of its first four songs in a grid, or the one
/// picture when it has fewer than four (a grid with gaps in it would look broken).
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.thumbs,
    required this.size,
    this.radius = SapocheTheme.artworkRadius,
    this.sharp = false,
  });

  final List<String> thumbs;
  final double size;
  final double radius;

  /// For a cover shown big, as in [Artwork].
  final bool sharp;

  @override
  Widget build(BuildContext context) {
    // Video thumbnails are wide: a picture is the middle of one, cropped square. A big cover asks for the largest
    // picture and, where there is none, falls back to this one, which has no black bars
    Widget picture(int i, double side, double radius) => Artwork(
      url: i < thumbs.length ? barlessThumbnail(thumbs[i]) : null,
      size: side,
      radius: radius,
      sharp: sharp,
      wide: !sharp,
    );
    if (thumbs.length < 4) return picture(0, size, radius);
    final half = size / 2;
    Widget tile(int i) => picture(i, half, 0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Column(
          children: [
            Row(children: [tile(0), tile(1)]),
            Row(children: [tile(2), tile(3)]),
          ],
        ),
      ),
    );
  }
}
