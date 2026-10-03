import 'package:flutter/material.dart';

import '../data/home_model.dart';
import '../data/models.dart';
import '../data/music_models.dart';
import '../data/song_key.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'home_shell.dart';
import 'collection_screen.dart';
import 'player/track_section.dart';
import 'scope.dart';
import 'settings_page.dart';
import 'widgets/artwork.dart';
import 'widgets/play_actions.dart';
import 'widgets/play_row.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/song_card.dart';

/// Where the app opens: what to play next, drawn from what the person listens to, like the home of YouTube Music.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    // The page scrolls up under the status bar, where its glass edge blurs it away
    final top = MediaQuery.paddingOf(context).top;
    return ScrollEdge(
      title: _Header.greeting(DateTime.now().hour),
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final home = buildHome(
            recent: library.recent,
            liked: library.liked,
            forYou: library.forYou,
            seedLists: library.seedLists,
            now: DateTime.now(),
            discover: library.discover,
            context: library.context,
            blocked: library.blocked,
          );
          return RefreshIndicator(
            onRefresh: library.refreshForYou,
            edgeOffset: top,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                top: top,
                bottom: HomeShell.bottomInsetOf(context),
              ),
              children: [
                const _Header(),
                if (home.isEmpty) const _Welcome(),
                _QuickPicks(tracks: home.quickPicks),
                CardShelf(
                  title: S.listenAgain,
                  cards: [
                    for (final t in home.listenAgain)
                      SongCard.track(
                        context,
                        t,
                        onTap: () => playNow(context, t),
                      ),
                  ],
                ),
                CardShelf(
                  title: S.contextMix(home.contextBucket),
                  cards: [
                    for (final t in home.context)
                      SongCard.track(
                        context,
                        t,
                        onTap: () => playNow(context, t),
                      ),
                  ],
                ),
                CardShelf(
                  title: S.mixedForYou,
                  cards: [
                    for (final mix in home.mixes)
                      SongCard(
                        title: S.mixOf(mix.artist),
                        subtitle: '',
                        thumb: mix.seed.thumb,
                        onTap: () => startMix(context, mix.seed),
                      ),
                  ],
                ),
                CardShelf(
                  title: S.discoverShelf,
                  cards: [
                    for (final t in home.discover)
                      SongCard.track(
                        context,
                        t,
                        onTap: () => playNow(context, t),
                      ),
                  ],
                ),
                CardShelf(
                  title: S.forgottenFavorites,
                  cards: [
                    for (final t in home.forgotten)
                      SongCard.track(
                        context,
                        t,
                        onTap: () => playNow(context, t),
                      ),
                  ],
                ),
                for (final b in home.becauseOf)
                  CardShelf(
                    title: S.becauseYouListened(b.seed.title),
                    cards: [
                      for (final t in b.tracks)
                        SongCard.track(
                          context,
                          t,
                          onTap: () => playNow(context, t),
                        ),
                    ],
                  ),
                if (home.topSeed != null) _SimilarArtists(seed: home.topSeed!),
                const _Trending(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  static String greeting(int hour) => hour < 12
      ? S.goodMorning
      : hour < 18
      ? S.goodAfternoon
      : S.goodEvening;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              greeting(DateTime.now().hour),
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          IconButton(
            onPressed: () => openSettings(context),
            tooltip: S.settingsTitle,
            style: roundButtonStyle(context, size: 40),
            // A dot while a newer version of the app is waiting
            icon: ListenableBuilder(
              listenable: AppScope.of(context).update,
              builder: (context, _) => Badge(
                key: const ValueKey('update-dot'),
                smallSize: 9,
                backgroundColor: p.primary,
                isLabelVisible: AppScope.of(context).update.info.hasUpdate,
                child: Icon(Icons.settings_outlined, size: 22, color: p.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Said while nothing is known about the person yet.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.veil,
          borderRadius: BorderRadius.circular(SapocheTheme.groupRadius),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: p.primary, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.homeEmptyTitle, style: theme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    S.homeEmptyBody,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Songs in columns of four that scroll sideways, each a row to touch.
class _QuickPicks extends StatelessWidget {
  const _QuickPicks({required this.tracks});

  final List<Track> tracks;

  static const _rows = 4;
  static const _rowHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final columns = (tracks.length / _rows).ceil();
    // A phone shows one column and a bit of the next; a wide window shows as many as fit
    final fit = (MediaQuery.sizeOf(context).width / 380).floor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(S.quickPicks),
        SizedBox(
          height: _rows * _rowHeight,
          child: PageView.builder(
            padEnds: false,
            controller: PageController(
              viewportFraction: fit < 2 ? 0.9 : 1 / fit.clamp(2, 4),
            ),
            itemCount: columns,
            itemBuilder: (context, column) => Column(
              children: [
                for (var r = 0; r < _rows; r++)
                  if (column * _rows + r < tracks.length)
                    _QuickRow(track: tracks[column * _rows + r])
                  else
                    const SizedBox(height: _QuickPicks._rowHeight),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => playNow(context, track),
      child: SizedBox(
        height: _QuickPicks._rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            children: [
              Artwork(url: track.thumb, size: 50, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.titleSmall,
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Artists like the one the person plays most. Asked for when the page shows, and left out if it fails.
class _SimilarArtists extends StatefulWidget {
  const _SimilarArtists({required this.seed});

  final Track seed;

  @override
  State<_SimilarArtists> createState() => _SimilarArtistsState();
}

class _SimilarArtistsState extends State<_SimilarArtists> {
  Future<RelatedPage>? _related;
  String? _for;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_for != widget.seed.videoId) {
      _for = widget.seed.videoId;
      _related = AppScope.of(context).music.related(widget.seed.videoId);
    }
  }

  @override
  void didUpdateWidget(_SimilarArtists old) {
    super.didUpdateWidget(old);
    if (_for != widget.seed.videoId) {
      _for = widget.seed.videoId;
      _related = AppScope.of(context).music.related(widget.seed.videoId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RelatedPage>(
    future: _related,
    builder: (context, async) {
      final artists = async.data?.artists ?? const <ArtistCard>[];
      if (artists.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(S.similarTo(displayArtist(widget.seed.artist))),
          ArtistRow(artists: artists, onOpen: (id) => openArtist(context, id)),
        ],
      );
    },
  );
}

/// What YouTube Music shows everybody: the same for all, so it is the only thing there is at first.
class _Trending extends StatelessWidget {
  const _Trending();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MusicShelf>>(
    future: AppScope.of(context).music.trending(),
    builder: (context, async) {
      final shelves = async.data ?? const <MusicShelf>[];
      return Column(
        children: [
          for (final shelf in shelves.take(3)) ...[
            CardShelf(
              title: shelf.tracks.isNotEmpty && shelves.first == shelf
                  ? S.trending
                  : shelf.title,
              cards: [
                for (final t in shelf.tracks)
                  SongCard.track(context, t, onTap: () => playNow(context, t)),
                for (final list in shelf.playlists)
                  SongCard(
                    title: list.title,
                    subtitle: list.subtitle ?? '',
                    thumb: list.thumb,
                    onTap: () => openCollection(
                      context,
                      id: list.id,
                      title: list.title,
                      thumb: list.thumb,
                    ),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
