import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../format.dart';
import '../../theme/theme.dart';
import 'artwork.dart';
import '../scope.dart';
import 'like_button.dart';

/// One song in a list: cover, title, artist, and something on the right.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.leading,
    this.leadingOverlay,
    this.highlight = false,
    this.dimmed = false,
    this.dense = false,
  });

  final Track track;

  /// Replaces the artist line, e.g. "Added by Anna".
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Takes the place of the cover, e.g. the number of the song in an album.
  final Widget? leading;

  /// Drawn over the cover, e.g. the equalizer for the song that is playing.
  final Widget? leadingOverlay;
  final bool highlight;
  final bool dimmed;

  /// Rows closer together, for a list of songs with no cover to give each its height.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 20,
            vertical: dense ? 0 : 7,
          ),
          child: Row(
            children: [
              leading ??
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
                    // A song with nothing to say about it (an album's, by the one artist) has the title alone
                    if ((subtitle ?? track.artist).isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          // A song that is on the phone says so
                          ListenableBuilder(
                            listenable: AppScope.of(context).library,
                            builder: (context, _) =>
                                AppScope.of(context).library
                                        .downloadState(track.videoId) ==
                                    DownloadState.done
                                ? Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.download_done_rounded,
                                      size: 15,
                                      color: p.primary,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          Expanded(
                            child: Text(
                              subtitle ?? track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.bodyMedium?.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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
