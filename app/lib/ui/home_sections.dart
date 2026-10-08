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
import 'widgets/artwork.dart';
import 'widgets/music_shelf.dart';
import 'widgets/not_interested.dart';
import 'widgets/play_actions.dart';
import 'widgets/playlist_cover.dart';
import 'widgets/song_card.dart';

/// Wraps what a row of the home page shows once it has something to show: the page uses it to count the rows that were
/// seen and touched (see `ShelfStats`). A row that is not made of this does not count.
typedef ShelfFrame = Widget Function(Widget shelf);

Widget _plain(Widget shelf) => shelf;

/// The moods YouTube Music offers (Relax, Workout, Focus...) as pills that scroll sideways; a touch opens what suits
/// the mood. Nothing is drawn while they are being asked for, or when they cannot be had.
class MoodChips extends StatefulWidget {
  const MoodChips({super.key});

  @override
  State<MoodChips> createState() => _MoodChipsState();
}

class _MoodChipsState extends State<MoodChips> {
  Future<MusicHome>? _home;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _home ??= AppScope.of(context).music.home();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FutureBuilder<MusicHome>(
      future: _home,
      builder: (context, async) {
        final chips = async.data?.chips ?? const <MoodChip>[];
        if (chips.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => Material(
              color: p.text.withValues(alpha: 0.1),
              shape: const StadiumBorder(),
              child: InkWell(
                key: ValueKey('mood-${chips[i].params}'),
                customBorder: const StadiumBorder(),
                onTap: () => openMood(context, chips[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Text(
                      chips[i].label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The songs heard last as small tiles in two columns (three on a wide page), the way Spotify opens: one touch and the
/// music is back.
class JumpBackIn extends StatelessWidget {
  const JumpBackIn({super.key, required this.tracks});

  final List<Track> tracks;

  static const _gap = 10.0;
  static const _height = 56.0;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
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
              for (final track in tracks.take(columns * 3))
                SizedBox(
                  width: width,
                  height: _height,
                  child: Material(
                    color: p.veil,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('jump-${track.videoId}'),
                      onTap: () => playNow(context, track),
                      onLongPress: () => showNotInterested(context, track),
                      child: Row(
                        children: [
                          Artwork(url: track.thumb, size: _height, radius: 0),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              track.title,
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
