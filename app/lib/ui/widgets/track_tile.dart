import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../format.dart';
import '../../theme/theme.dart';
import 'artwork.dart';
import 'like_button.dart';

/// One song in a list: cover, title, artist, and something on the right.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.leadingOverlay,
    this.highlight = false,
    this.dimmed = false,
  });

  final Track track;

  /// Replaces the artist line, e.g. "Added by Anna".
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Drawn over the cover, e.g. the equalizer for the song that is playing.
  final Widget? leadingOverlay;
  final bool highlight;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Artwork(url: track.thumb, size: 54),
                  if (leadingOverlay != null)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.38),
                          borderRadius: BorderRadius.circular(
                            UnisonTheme.artworkRadius,
                          ),
                        ),
                        child: Center(child: leadingOverlay),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.titleMedium?.copyWith(
                        color: highlight ? p.primary : p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else ...[
                LikeButton(track: track, size: 20),
                if (track.durMs > 0)
                  Text(
                    formatDuration(track.durMs),
                    style: theme.bodySmall?.copyWith(color: p.textTertiary),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
