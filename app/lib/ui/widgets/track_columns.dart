import 'package:flutter/material.dart';

import '../../data/music_models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';

/// What a list of songs says to its rows about itself, so that in a wide window they can stand in columns, as in
/// Spotify's: the song, its album, its length. A list opens one with [TrackColumnsScope]; a row outside any has no album.
class TrackColumns extends InheritedWidget {
  const TrackColumns({super.key, required this.album, required super.child});

  /// Whether the list has an album to say for some of its songs. With none, the column would be a gap, and is left out.
  final bool album;

  static bool albumOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackColumns>()?.album ??
      false;

  /// The window is wide and the row long enough for columns: the sidebar layout, and a row of [minRow] dp or more.
  static bool fits(BuildContext context, double rowWidth) =>
      HomeShell.layoutOf(context) == ShellLayout.sidebar && rowWidth >= minRow;

  static const minRow = 720.0;

  /// How wide the content of a row is allowed to be: with the album column it is the width of a page; without it, one
  /// song's line reads best near, and a longer one only puts the name and the length far from each other.
  static double maxContent({required bool album}) => album ? 1180 : 760;

  /// Share of the room the title and the album have, once the length and the buttons are taken off.
  static const titleFlex = 5;
  static const albumFlex = 3;

  /// The width of the length, and of the buttons after it (the "…" menu is a 48 dp button).
  static const lengthWidth = 56.0;

  /// The same for a list of songs of which [album] says whether some have an album.
  @override
  bool updateShouldNotify(TrackColumns old) => album != old.album;
}

/// Opens a list of songs: [tracks] says whether the album column is wanted, by whether any song has one.
class TrackColumnsScope extends StatelessWidget {
  const TrackColumnsScope({
    super.key,
    required this.tracks,
    required this.child,
  });

  final Iterable<Object> tracks;
  final Widget child;

  @override
  Widget build(BuildContext context) => TrackColumns(
    album: tracks.any((t) => t is MusicTrack && (t.album ?? '').isNotEmpty),
    child: child,
  );
}

/// The thin row of names over the columns of a list of songs, in a wide window; nothing in a narrow one.
class TrackColumnsHeader extends StatelessWidget {
  const TrackColumnsHeader({super.key});

  /// Where the title starts: the padding of a row, a cover and the gap after it.
  static const _titleAt = 20 + 54 + 14.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(
      builder: (context, box) {
        if (!TrackColumns.fits(context, box.maxWidth)) {
          return const SizedBox.shrink();
        }
        final album = TrackColumns.albumOf(context);
        final style = Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: p.textTertiary, letterSpacing: 0.4);
        return Padding(
          padding: const EdgeInsets.fromLTRB(_titleAt, 4, 20, 4),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: TrackColumns.maxContent(album: album) - _titleAt + 20,
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: TrackColumns.titleFlex,
                    child: Text(S.sortTitle, style: style, maxLines: 1),
                  ),
                  if (album)
                    Expanded(
                      flex: TrackColumns.albumFlex,
                      child: Text(S.infoAlbum, style: style, maxLines: 1),
                    ),
                  SizedBox(
                    width: TrackColumns.lengthWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Tooltip(
                        message: S.infoLength,
                        child: Icon(
                          Icons.schedule_rounded,
                          size: 15,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                  ),
                  // Where the "…" button of a row is
                  const SizedBox(width: 56),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Keeps what goes with a list of songs (the card of the song playing, the heading with its buttons) to the width of the
/// rows under it in a wide window, so that the buttons are not a screen away from what they are for.
class ListWidth extends StatelessWidget {
  const ListWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (!TrackColumns.fits(context, box.maxWidth)) return child;
      return Align(
        alignment: Alignment.topLeft,
        // The padding of the rows at each side comes with the content
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: TrackColumns.maxContent(album: false) + 40,
          ),
          child: child,
        ),
      );
    },
  );
}
