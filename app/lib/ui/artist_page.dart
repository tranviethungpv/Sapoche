import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/music_models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'collection_screen.dart';
import 'player/player_message.dart';
import 'player/track_section.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/music_shelf.dart';
import 'widgets/play_row.dart';
import 'widgets/player_backdrop.dart';

/// Opens the page of an artist in the tab that is showing, with a way back.
Future<void> openArtist(BuildContext context, String artistId) {
  // A message still showing would be drawn by the new page too, and the two would fight over it
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  return TabNavigation.push(
    context,
    MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: artistId)),
  );
}

/// An artist: picture, what they say about themselves, their best known songs and who else to listen to.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Future<ArtistPage>? _page;

  void _load() {
    _page = AppScope.of(context).music.artist(widget.artistId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_page == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArtistPage>(
      future: _page,
      builder: (context, async) {
        final page = async.data;
        final failed = async.hasError || (page != null && page.name.isEmpty);
        // The page takes its colours from the picture, as the page of an album does
        return Stack(
          fit: StackFit.expand,
          children: [
            PlayerBackdrop(coverUrl: page?.thumb),
            Scaffold(
              appBar: AppBar(leading: const RoundBackButton()),
              body: switch (page) {
                _ when failed => PlayerMessage(
                  icon: Icons.cloud_off_rounded,
                  text: S.musicFailed,
                  action: S.tryAgain,
                  onAction: () => setState(_load),
                ),
                null => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                _ => _Content(page: page),
              },
            ),
          ],
        );
      },
    );
  }
}

class _Content extends StatefulWidget {
  const _Content({required this.page});

  final ArtistPage page;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  bool _open = false;
  PlayWorking _working = PlayWorking.none;

  ArtistPage get _page => widget.page;

  /// What Play and Shuffle take: all of the top songs when YouTube Music keeps them in a playlist, else the few
  /// that are on the page. A page with neither (a profile) has nothing to play from here.
  Future<List<MusicTrack>> _songs() async {
    final id = _page.topSongsId;
    if (id != null) {
      try {
        final all = await AppScope.of(context).music.collection(id);
        if (all.tracks.isNotEmpty) return all.tracks;
      } on Object {
        // The few on the page will do
      }
    }
    return _page.topSongs;
  }

  Future<void> _play({required bool shuffle}) async {
    if (_working != PlayWorking.none) return;
    HapticFeedback.selectionClick();
    setState(() => _working = shuffle ? PlayWorking.shuffle : PlayWorking.play);
    final songs = [...await _songs()];
    if (!mounted) return;
    setState(() => _working = PlayWorking.none);
    if (songs.isEmpty) return;
    if (shuffle) songs.shuffle();
    await AppScope.roomOf(context).playTracks(songs);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.only(bottom: HomeShell.bottomInsetOf(context)),
      children: [
        _Hero(page: page),
        if (page.topSongs.isNotEmpty || page.topSongsId != null)
          PlayRow(
            working: _working,
            onPlay: () => _play(shuffle: false),
            onShuffle: () => _play(shuffle: true),
          ),
        TrackSection(
          title: S.topSongs,
          tracks: page.topSongs,
          headerAction: page.topSongsId == null
              ? null
              : TextButton(
                  onPressed: () => openCollection(
                    context,
                    id: page.topSongsId!,
                    title: S.topSongs,
                  ),
                  child: Text(S.seeAll),
                ),
        ),
        _releases(S.albums, page.albums),
        _releases(S.singlesAndEps, page.singles),
        for (final shelf in page.shelves) MusicShelfView(shelf: shelf),
        if (page.similar.isNotEmpty) ...[
          SectionHeading(S.fansAlsoLike),
          ArtistRow(
            artists: page.similar,
            onOpen: (id) => openArtist(context, id),
          ),
        ],
        if (page.description != null) ...[
          SectionHeading(S.aboutArtist),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              onTap: () => setState(() => _open = !_open),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                alignment: Alignment.topCenter,
                child: Text(
                  page.description!,
                  maxLines: _open ? null : 5,
                  overflow: _open
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(_open ? S.showLess : S.showMore),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// A row of albums or singles to open.
  Widget _releases(String title, List<Release> releases) => MusicShelfView(
    shelf: MusicShelf(title: title, albums: releases),
  );
}

/// The picture of the artist across the page, with the name and what is known of their reach on it.
class _Hero extends StatelessWidget {
  const _Hero({required this.page});

  final ArtistPage page;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context).width - 40;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              page.thumb == null
                  ? ColoredBox(
                      color: p.primaryContainer,
                      child: Icon(
                        Icons.person_rounded,
                        size: size * 0.3,
                        color: p.primary,
                      ),
                    )
                  : Artwork(
                      url: page.thumb,
                      size: size,
                      radius: 0,
                      sharp: true,
                    ),
              // Dark at the bottom, so the name reads on any picture
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.45, 1],
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      page.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.headlineLarge?.copyWith(color: Colors.white),
                    ),
                    if (page.subscribers != null)
                      Text(
                        S.subscribers(
                          page.subscribers!.replaceAll(' subscribers', ''),
                        ),
                        style: theme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
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
