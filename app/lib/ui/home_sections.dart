import 'package:flutter/material.dart';

import '../data/home_model.dart';
import '../data/models.dart';
import '../data/music_models.dart';
import '../data/new_releases.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'collection_screen.dart';
import 'home_shell.dart';
import 'mood_page.dart';
import 'player/track_section.dart';
import 'scope.dart';
import 'widgets/music_shelf.dart';
import 'widgets/play_actions.dart';
import 'widgets/playlist_cover.dart';
import 'widgets/song_card.dart';

/// Wraps what a row of the home page shows once it has something to show: the page uses it to count the rows that were
/// seen and touched (see `ShelfStats`). A row that is not made of this does not count.
typedef ShelfFrame = Widget Function(Widget shelf);

Widget _plain(Widget shelf) => shelf;

/// One of the person's own chips: a list of songs made from their music, which a touch plays.
class PersonalChip {
  const PersonalChip({
    required this.id,
    required this.label,
    required this.tracks,
  });

  final String id;
  final String label;
  final List<Track> tracks;
}

/// The chips at the top of the page, in a row that scrolls sideways.
///
/// First the person's own: their mixes, the mix for this time of day, the favourites they have not heard for a long
/// while, something new. They are made on the phone from what the person plays, and a touch starts them. Then the moods
/// YouTube Music offers (Relax, Workout, Focus...), whose touch opens the playlists that suit the mood.
///
/// The moods are the same for everybody, and YouTube's playlists of a mood hold hardly any of the songs a person plays
/// (measured: a handful of 300 to 1300), so a mood cannot be made theirs; the own chips are what is. Both kinds are
/// shown in the order the person touches them at this time of day (see `ShelfStats`), the own ones first. The moods
/// are left out while they are asked for, or when they cannot be had.
class HomeChips extends StatefulWidget {
  const HomeChips({super.key, this.personal = const []});

  final List<PersonalChip> personal;

  @override
  State<HomeChips> createState() => _HomeChipsState();
}

class _HomeChipsState extends State<HomeChips> {
  Future<List<MoodChip>>? _moods;
  late String _part;

  /// The own chips as they were last put in order: the order is drawn when the set of chips changes, not each time the
  /// page is drawn, so that it does not shuffle under the person's finger.
  String? _key;
  List<String> _order = const [];

  String _moodId(MoodChip chip) => 'mood:${chip.params}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_moods != null) return;
    final model = AppScope.of(context);
    _part = dayPartOf(DateTime.now());
    // Drawn once too, when the moods arrive
    _moods = model.music
        .home()
        .then((home) {
          final byId = {for (final chip in home.chips) _moodId(chip): chip};
          if (byId.isEmpty) return const <MoodChip>[];
          model.settings.shelves.shown(_part, byId.keys);
          return [
            for (final id in model.settings.shelves.order(
              byId.keys.toList(),
              _part,
            ))
              byId[id]!,
          ];
        })
        .catchError((_) => const <MoodChip>[]);
  }

  List<PersonalChip> _personal() {
    final stats = AppScope.of(context).settings.shelves;
    final byId = {for (final c in widget.personal) 'me:${c.id}': c};
    final key = byId.keys.join(',');
    if (key != _key) {
      _key = key;
      if (byId.isNotEmpty) stats.shown(_part, byId.keys);
      _order = stats.order(byId.keys.toList(), _part);
    }
    return [for (final id in _order) byId[id]!];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final stats = AppScope.of(context).settings.shelves;
    final personal = _personal();
    return FutureBuilder<List<MoodChip>>(
      future: _moods,
      builder: (context, async) {
        final moods = async.data ?? const <MoodChip>[];
        final count = personal.length + moods.length;
        if (count == 0) return const SizedBox.shrink();
        Widget pill({
          required Key key,
          required String label,
          required VoidCallback onTap,
          bool own = false,
        }) => Material(
          color: own ? p.primaryContainer : p.text.withValues(alpha: 0.1),
          shape: const StadiumBorder(),
          child: InkWell(
            key: key,
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(own ? 10 : 16, 0, 16, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The own chips play at a touch: the arrow says so
                  if (own) ...[
                    Icon(
                      Icons.play_arrow_rounded,
                      size: 20,
                      color: p.onPrimaryContainer,
                    ),
                    const SizedBox(width: 2),
                  ],
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: own ? p.onPrimaryContainer : null),
                  ),
                ],
              ),
            ),
          ),
        );
        return SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (i < personal.length) {
                final chip = personal[i];
                return pill(
                  key: ValueKey('chip-${chip.id}'),
                  label: chip.label,
                  own: true,
                  onTap: () {
                    stats.touched(_part, 'me:${chip.id}');
                    playMix(context, chip.tracks);
                  },
                );
              }
              final mood = moods[i - personal.length];
              return pill(
                key: ValueKey('mood-${mood.params}'),
                label: mood.label,
                onTap: () {
                  stats.touched(_part, _moodId(mood));
                  openMood(context, mood);
                },
              );
            },
          ),
        );
      },
    );
  }
}

/// One of the tiles at the top of the page: a way into something of the person's.
class QuickTile {
  const QuickTile({
    required this.id,
    required this.title,
    required this.cover,
    required this.onTap,
  });

  final String id;
  final String title;

  /// The picture of the tile, square, [side] points a side.
  final Widget Function(double side) cover;
  final VoidCallback onTap;
}

/// The person's own things as small tiles in two columns (three on a wide page), the way Spotify opens: the songs
/// they liked, what they downloaded, their playlists and the artists they play most. One touch and it is open or
/// playing.
class QuickAccess extends StatelessWidget {
  const QuickAccess({super.key, required this.tiles});

  final List<QuickTile> tiles;

  static const _gap = 10.0;
  static const _height = 56.0;

  @override
  Widget build(BuildContext context) {
    // A single tile on its own looks like a mistake
    if (tiles.length < 2) return const SizedBox.shrink();
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: LayoutBuilder(
        builder: (context, box) {
          final columns = box.maxWidth >= 760 ? 3 : 2;
          final width = (box.maxWidth - _gap * (columns - 1)) / columns;
          return Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [
              for (final tile in tiles)
                SizedBox(
                  width: width,
                  height: _height,
                  child: Material(
                    color: p.veil,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('quick-${tile.id}'),
                      onTap: tile.onTap,
                      child: Row(
                        children: [
                          tile.cover(_height),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              tile.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A tile cover that is a plain icon on the colour of the app: the liked songs and the downloads have no picture.
class QuickIconCover extends StatelessWidget {
  const QuickIconCover(this.icon, {super.key, required this.side});

  final IconData icon;
  final double side;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.primary, p.primary.withValues(alpha: 0.55)],
        ),
      ),
      child: Icon(icon, color: p.onPrimary, size: side * 0.42),
    );
  }
}

/// The mixes made for the person, one for each kind of music they come back to: a cover of four pictures, its number
/// and who is in it.
class MadeForYou extends StatelessWidget {
  const MadeForYou({super.key, required this.mixes});

  final List<DailyMix> mixes;

  @override
  Widget build(BuildContext context) {
    if (mixes.isEmpty) return const SizedBox.shrink();
    final size = HomeShell.cardSizeOf(context) + 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(S.madeForYou),
        SizedBox(
          // The cover and two lines under it
          height: size + 66,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: mixes.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => _MixCard(mix: mixes[i], size: size),
          ),
        ),
      ],
    );
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({required this.mix, required this.size});

  final DailyMix mix;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      key: ValueKey('mix-${mix.number}'),
      onTap: () => playMix(context, mix.tracks),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                PlaylistCover(thumbs: mix.covers, size: size, radius: 16),
                // A fade drawn once, not a blur: the words stay readable on any picture
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0x99000000)],
                        stops: [0.45, 1],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 10,
                  child: Text(
                    S.dailyMix(mix.number),
                    style: theme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(5),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: Color(0xFF22161A),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              S.mixArtists(mix.artists),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.bodySmall?.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// The newest album or single of the artists the person plays most, found on their pages. Nothing is drawn until some
/// is found, and nothing if none is.
class LatestReleasesShelf extends StatefulWidget {
  const LatestReleasesShelf({
    super.key,
    required this.artists,
    this.frame = _plain,
  });

  final List<ArtistMix> artists;
  final ShelfFrame frame;

  @override
  State<LatestReleasesShelf> createState() => _LatestReleasesShelfState();
}

class _LatestReleasesShelfState extends State<LatestReleasesShelf> {
  Future<List<LatestRelease>>? _found;
  String? _for;

  void _look() {
    final key = widget.artists.map((a) => a.seed.videoId).join(',');
    if (key == _for) return;
    _for = key;
    _found = widget.artists.isEmpty
        ? Future.value(const [])
        : latestReleases(
            AppScope.of(context).music,
            widget.artists,
            now: DateTime.now(),
          );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _look();
  }

  @override
  void didUpdateWidget(LatestReleasesShelf old) {
    super.didUpdateWidget(old);
    _look();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<LatestRelease>>(
    future: _found,
    builder: (context, async) {
      final found = async.data ?? const <LatestRelease>[];
      if (found.isEmpty) return const SizedBox.shrink();
      return widget.frame(
        CardShelf(
          title: S.latestFromArtists,
          cards: [
            for (final f in found)
              SongCard(
                title: f.release.title,
                subtitle: '${f.artist} · ${f.year}',
                thumb: f.release.thumb,
                onTap: () => openCollection(
                  context,
                  id: f.release.id,
                  title: f.release.title,
                  thumb: f.release.thumb,
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// What is played most where the person lives: playlists of the charts and the artists on top.
class ChartsShelves extends StatelessWidget {
  const ChartsShelves({super.key, this.frame = _plain});

  final ShelfFrame frame;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MusicShelf>>(
    future: AppScope.of(context).music.charts(),
    builder: (context, async) {
      final shelves = async.data ?? const <MusicShelf>[];
      if (shelves.isEmpty) return const SizedBox.shrink();
      return frame(
        Column(
          children: [
            for (final shelf in shelves.take(2)) MusicShelfView(shelf: shelf),
          ],
        ),
      );
    },
  );
}
