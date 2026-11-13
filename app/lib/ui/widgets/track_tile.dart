import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../format.dart';
import '../../theme/theme.dart';
import 'artwork.dart';
import '../scope.dart';
import 'like_button.dart';
import 'menu_lines.dart' show SongMenuHandle;
import 'meta_line.dart';
import 'track_columns.dart';
import '../collection_screen.dart' show openCollection;

/// Lets the "…" menu in a row's trailing be opened by the row itself, from a right click, as a mouse (DeX, a computer)
/// does. The row provides the handle and the menu takes it.
class RowMenuKey extends InheritedWidget {
  const RowMenuKey({super.key, required this.menuKey, required super.child});

  final SongMenuHandle menuKey;

  static SongMenuHandle? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<RowMenuKey>()?.menuKey;

  @override
  bool updateShouldNotify(RowMenuKey old) => false;
}

/// One song in a list: cover, title, artist, and something on the right.
class TrackTile extends StatefulWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.subtitle,
    this.meta,
    this.lead,
    this.trailing,
    this.onTap,
    this.leading,
    this.leadingOverlay,
    this.badge,
    this.highlight = false,
    this.dimmed = false,
    this.dense = false,
  });

  final Track track;

  /// Replaces the artist line, e.g. "Added by Anna".
  final String? subtitle;

  /// A count ("1.8B views") at the end of the line under the title, which gives way before the artist is cut.
  final String? meta;

  /// What kind of thing it is ("Song"), at the start of that line, the first to give way.
  final String? lead;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Takes the place of the cover, e.g. the number of the song in an album.
  final Widget? leading;

  /// Drawn over the cover, e.g. the equalizer for the song that is playing.
  final Widget? leadingOverlay;

  /// Small, on the corner of the cover, e.g. the picture of the person who added the song.
  final Widget? badge;
  final bool highlight;
  final bool dimmed;

  /// Rows closer together, for a list of songs with no cover to give each its height.
  final bool dense;

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> {
  final _menu = SongMenuHandle();

  @override
  Widget build(BuildContext context) {
    final TrackTile(
      :track,
      :subtitle,
      :meta,
      :lead,
      :trailing,
      :onTap,
      :leading,
      :leadingOverlay,
      :badge,
      :highlight,
      :dimmed,
      :dense,
    ) = widget;
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final length = track.durMs > 0
        ? Text(
            formatDuration(track.durMs),
            textAlign: TextAlign.end,
            style: theme.bodySmall?.copyWith(color: p.textTertiary),
          )
        : null;
    Widget picture() =>
        Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Artwork(url: track.thumb, size: 54),
            if (leadingOverlay != null)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(
                      SapocheTheme.artworkRadius,
                    ),
                  ),
                  child: Center(child: leadingOverlay),
                ),
              ),
            if (badge != null) Positioned(right: -6, bottom: -6, child: badge),
          ],
        );
    // A song that cannot be chosen (heard already, its file gone) is dimmed in its picture, never in its words: their
    // colour is the one that keeps 4.5:1, and a row faded as a whole put them at 2.3:1
    Widget cover() => Opacity(opacity: dimmed ? 0.5 : 1, child: leading ?? picture());
    final names = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.titleMedium?.copyWith(
            color: highlight
                ? p.primary
                : dimmed
                ? p.textSecondary
                : p.text,
          ),
        ),
        // A song with nothing to say about it (an album's, by the one artist) has the title alone
        if ((subtitle ?? track.artist).isNotEmpty || meta != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              // A song that is on the phone says so, and one on its way says where it stands
              ListenableBuilder(
                listenable: AppScope.of(context).library.downloadNews,
                builder: (context, _) => _DownloadMark(track.videoId),
              ),
              Expanded(
                child: MetaLine(
                  text: subtitle ?? track.artist,
                  meta: meta,
                  lead: lead,
                  style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    return RowMenuKey(
      menuKey: _menu,
      child: InkWell(
        onTap: onTap,
        onSecondaryTap: () => _menu.open?.call(),
        child: LayoutBuilder(
          builder: (context, box) {
            // In a wide window the row stands in columns: the song, its album if the list has one, its length
            final columns = TrackColumns.fits(context, box.maxWidth);
            final album = columns && TrackColumns.albumOf(context);
            final row = Row(
              children: [
                cover(),
                const SizedBox(width: 14),
                Expanded(
                  flex: columns ? TrackColumns.titleFlex : 1,
                  // The album column starts a little way from where a long title ends
                  child: album
                      ? Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: names,
                        )
                      : names,
                ),
                if (album)
                  Expanded(
                    flex: TrackColumns.albumFlex,
                    child: _AlbumCell(track: track),
                  ),
                if (columns) ...[
                  SizedBox(
                    width: TrackColumns.lengthWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: length,
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ] else
                    LikeButton(track: track, size: 20),
                ] else if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing,
                ] else ...[
                  LikeButton(track: track, size: 20),
                  // A row with no length keeps the room for one, so its heart stands where the other rows' do
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 36),
                    child: length,
                  ),
                ],
              ],
            );
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 20,
                vertical: dense ? 0 : 7,
              ),
              child: ConstrainedBox(
                // A row of an album is never lower than a thing to touch, whatever its text
                constraints: BoxConstraints(
                  minHeight: dense ? 52 : 0,
                  maxWidth: columns
                      ? TrackColumns.maxContent(album: album)
                      : double.infinity,
                ),
                child: columns
                    ? Align(alignment: Alignment.centerLeft, child: row)
                    : row,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The album of a song in the column of that name: its words, and a touch on them opens the album.
class _AlbumCell extends StatelessWidget {
  const _AlbumCell({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final track = this.track;
    final name = track is MusicTrack ? track.album : null;
    if (name == null || name.isEmpty) return const SizedBox.shrink();
    final id = (track as MusicTrack).albumId;
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: p.textSecondary),
    );
    if (id == null) {
      return Padding(padding: const EdgeInsets.only(right: 12), child: text);
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              openCollection(context, id: id, title: name, thumb: track.thumb),
          child: text,
        ),
      ),
    );
  }
}

/// Where a song stands on the way onto the phone, the size of a line of text: nothing when it was never asked for.
class _DownloadMark extends StatelessWidget {
  const _DownloadMark(this.videoId);

  final String videoId;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final p = context.palette;
    final Widget? mark;
    if (library.downloadBatch.value.active == videoId) {
      mark = SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: p.primary),
      );
    } else {
      mark = switch (library.downloadState(videoId)) {
        DownloadState.done => Icon(
          Icons.download_done_rounded,
          size: 15,
          color: p.primary,
        ),
        DownloadState.queued || DownloadState.waiting => Icon(
          Icons.arrow_circle_down_outlined,
          size: 15,
          color: p.textTertiary,
        ),
        DownloadState.failed => Icon(
          Icons.error_outline_rounded,
          size: 15,
          color: p.error,
        ),
        null => null,
      };
    }
    if (mark == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: SizedBox.square(dimension: 15, child: Center(child: mark)),
    );
  }
}
