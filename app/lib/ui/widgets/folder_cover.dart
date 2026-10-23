import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'playlist_cover.dart';

/// The cover of a folder of playlists: the covers of its first playlists as a playlist's grid is made, with a small
/// folder on a corner so that it is not taken for a playlist, or a folder on a tile while it has nothing in it.
class FolderCover extends StatelessWidget {
  const FolderCover({
    super.key,
    required this.thumbs,
    required this.size,
    this.radius = SapocheTheme.artworkRadius,
    this.sharp = false,
  });

  /// One picture for each of the first playlists, up to four.
  final List<String> thumbs;
  final double size;
  final double radius;

  /// For a cover shown big, as in [PlaylistCover].
  final bool sharp;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (thumbs.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(Icons.folder_rounded, size: size * 0.42, color: p.primary),
      );
    }
    final badge = (size * 0.34).clamp(16.0, 56.0);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          PlaylistCover(
            thumbs: thumbs,
            size: size,
            radius: radius,
            sharp: sharp,
          ),
          Positioned(
            right: size * 0.05,
            bottom: size * 0.05,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.6),
              ),
              child: Icon(
                Icons.folder_rounded,
                size: badge * 0.58,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
