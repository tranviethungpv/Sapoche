import 'package:flutter/material.dart';

import '../data/music_models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'player/player_message.dart';
import 'player/track_section.dart';
import 'scope.dart';
import 'widgets/wash.dart';

/// Opens the page of an artist on top of everything, with a way back.
Future<void> openArtist(BuildContext context, String artistId) {
  // A message still showing would be drawn by the new page too, and the two would fight over it
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  return Navigator.of(context).push(
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

  void _load() => _page = AppScope.of(context).music.artist(widget.artistId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_page == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    // A page on its own has no backdrop: the pink veil is part of the home screen
    return PinkWash(
      child: Scaffold(
        appBar: AppBar(),
        body: FutureBuilder<ArtistPage>(
          future: _page,
          builder: (context, async) {
            if (async.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            if (async.hasError || async.data!.name.isEmpty) {
              return PlayerMessage(
                icon: Icons.cloud_off_rounded,
                text: S.musicFailed,
                action: S.tryAgain,
                onAction: () => setState(_load),
              );
            }
            return _Content(page: async.data!);
          },
        ),
      ),
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

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final room = AppScope.roomOf(context);
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Center(
          child: ClipOval(
            child: SizedBox.square(
              dimension: 160,
              child: page.thumb == null
                  ? ColoredBox(
                      color: p.primaryContainer,
                      child: Icon(
                        Icons.person_rounded,
                        size: 64,
                        color: p.primary,
                      ),
                    )
                  : Image.network(
                      page.thumb!,
                      fit: BoxFit.cover,
                      cacheWidth: 480,
                      errorBuilder: (_, _, _) =>
                          ColoredBox(color: p.primaryContainer),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            page.name,
            textAlign: TextAlign.center,
            style: theme.headlineMedium,
          ),
        ),
        if (page.subscribers != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              S.subscribers(page.subscribers!.replaceAll(' subscribers', '')),
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ),
        if (page.topSongs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: FilledButton.icon(
              onPressed: () {
                room.playTracks(page.topSongs);
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text(S.play),
            ),
          ),
        TrackSection(title: S.topSongs, tracks: page.topSongs),
        if (page.description != null) ...[
          const SectionHeading(S.aboutArtist),
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
        if (page.similar.isNotEmpty) ...[
          const SectionHeading(S.fansAlsoLike),
          ArtistRow(
            artists: page.similar,
            onOpen: (id) => openArtist(context, id),
          ),
        ],
      ],
    );
  }
}
