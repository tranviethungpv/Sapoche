import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/music_models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'home_shell.dart';
import 'player/player_message.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/music_shelf.dart';
import 'widgets/play_actions.dart';
import 'widgets/play_row.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/queue_actions.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// Opens an album or a playlist in the tab that is showing, with a way back. [title] and [thumb] are what the
/// person was looking at, shown until the page itself arrives.
Future<void> openCollection(
  BuildContext context, {
  required String id,
  String? title,
  String? thumb,
}) {
  // A message still showing would be drawn by the new page too, and the two would fight over it
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  return TabNavigation.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => CollectionScreen(id: id, title: title, thumb: thumb),
    ),
  );
}

/// An album or a playlist, in the manner of Apple Music: its cover, who made it, play and shuffle, the songs
/// numbered (for an album) or with their covers (for a playlist), and more to look at below.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key, required this.id, this.title, this.thumb});

  final String id;
  final String? title;
  final String? thumb;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  Future<CollectionPage>? _page;

  void _load() {
    _page = AppScope.of(context).music.collection(widget.id);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_page == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CollectionPage>(
      future: _page,
      builder: (context, async) {
        final page = async.data;
        // The page takes its colours from the cover, which is known from the start when it was tapped on a card
        return Stack(
          fit: StackFit.expand,
          children: [
            PlayerBackdrop(coverUrl: page?.thumb ?? widget.thumb),
            if (page != null)
              _Content(page: page)
            else
              Scaffold(
                appBar: AppBar(leading: const RoundBackButton()),
                body: async.hasError
                    ? PlayerMessage(
                        icon: Icons.cloud_off_rounded,
                        text: S.playlistFailed,
                        action: S.tryAgain,
                        onAction: () => setState(_load),
                      )
                    : _Waiting(title: widget.title, thumb: widget.thumb),
              ),
          ],
        );
      },
    );
  }
}

/// What the person tapped on, until the page arrives.
class _Waiting extends StatelessWidget {
  const _Waiting({this.title, this.thumb});

  final String? title;
  final String? thumb;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Cover(url: thumb),
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
            child: Text(
              title!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        const Expanded(
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ],
    );
  }
}

/// The cover, large and with a soft shadow.
class _Cover extends StatelessWidget {
  const _Cover({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).width * 0.74).clamp(200.0, 320.0);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Artwork(url: url, size: size, radius: 16, sharp: true),
      ),
    );
  }
}

class _Content extends StatefulWidget {
  const _Content({required this.page});

  final CollectionPage page;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  /// How many songs Play, Shuffle and the menu take from a long playlist: what a queue holds.
  static const _cap = 200;

  final _scroll = ScrollController();
  late final List<MusicTrack> _tracks = [...widget.page.tracks];
  late String? _more = widget.page.more;
  bool _loadingMore = false;
  bool _moreFailed = false;
  bool _open = false;
  PlayWorking _working = PlayWorking.none;

  CollectionPage get _page => widget.page;
  bool get _isAlbum =>
      _page.id.startsWith('MPRE') ||
      const {'Album', 'Single', 'EP'}.contains(_page.kind);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_more != null &&
        !_loadingMore &&
        !_moreFailed &&
        _scroll.position.extentAfter < 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final token = _more;
    if (token == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final next = await AppScope.of(context).music.more(token);
      if (!mounted) return;
      setState(() {
        _tracks.addAll(next.tracks);
        _more = next.more;
        _loadingMore = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  /// Every song there is, up to [_cap]: the rest of a long playlist is asked for first. When that fails the songs
  /// that are here will do.
  Future<List<MusicTrack>> _everySong() async {
    final songs = [..._tracks];
    var token = _more;
    final music = AppScope.of(context).music;
    try {
      while (token != null && songs.length < _cap) {
        final next = await music.more(token);
        songs.addAll(next.tracks);
        token = next.more;
      }
    } on Object {
      // What is here is enough to go on with
    }
    return songs.take(_cap).toList();
  }

  Future<void> _playAll({required bool shuffle}) async {
    if (_working != PlayWorking.none) return;
    HapticFeedback.selectionClick();
    setState(() => _working = shuffle ? PlayWorking.shuffle : PlayWorking.play);
    final songs = await _everySong();
    if (!mounted) return;
    setState(() => _working = PlayWorking.none);
    if (songs.isEmpty) return;
    if (shuffle) songs.shuffle();
    final room = AppScope.roomOf(context);
    final inRoom = room.snapshot.inRoom;
    final messenger = ScaffoldMessenger.of(context);
    await room.playTracks(songs);
    // In a room the songs are only put on the queue: say so
    if (inRoom) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(S.playlistAdded),
            duration: const Duration(milliseconds: 1400),
          ),
        );
    }
  }

  Future<void> _menu(String action) async {
    if (_working != PlayWorking.none) return;
    setState(() => _working = PlayWorking.other);
    final songs = await _everySong();
    if (!mounted) return;
    setState(() => _working = PlayWorking.none);
    if (songs.isEmpty) return;
    switch (action) {
      case 'next':
        await queueTracks(context, songs, playNext: true);
      case 'queue':
        await queueTracks(context, songs);
      default:
        final messenger = ScaffoldMessenger.of(context);
        final saved = await AppScope.of(context).library
            .createPlaylist(_page.title, songs);
        if (saved == null) return;
        HapticFeedback.selectionClick();
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(S.playlistSaved)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final meta = [
      if (_page.kind != null) S.collectionKind(_page.kind!),
      ?_page.year,
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(leading: const RoundBackButton()),
      body: CustomScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Center(child: _Cover(url: _page.thumb)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                  child: Text(
                    _page.title,
                    textAlign: TextAlign.center,
                    style: theme.headlineSmall,
                  ),
                ),
                if (_page.owner != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    child: GestureDetector(
                      onTap: _page.ownerId == null
                          ? null
                          : () => openArtist(context, _page.ownerId!),
                      child: Text(
                        _page.owner!,
                        textAlign: TextAlign.center,
                        style: theme.titleMedium?.copyWith(
                          color: _page.ownerId == null
                              ? p.textSecondary
                              : p.primary,
                        ),
                      ),
                    ),
                  ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      meta,
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ),
                PlayRow(
                  working: _working,
                  onPlay: () => _playAll(shuffle: false),
                  onShuffle: () => _playAll(shuffle: true),
                  more: PopupMenuButton<String>(
                    tooltip: S.showMore,
                    icon: _working == PlayWorking.other
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.more_horiz_rounded),
                    style: roundButtonStyle(context),
                    color: p.brightness == Brightness.light
                        ? const Color(0xFFFFF7F9)
                        : const Color(0xFF2B1F25),
                    surfaceTintColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    onSelected: _menu,
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'next', child: Text(S.playNext)),
                      PopupMenuItem(value: 'queue', child: Text(S.addToQueue)),
                      PopupMenuItem(
                        value: 'save',
                        child: Text(S.saveAsPlaylist),
                      ),
                    ],
                  ),
                ),
                if (_page.description != null) _description(context),
                const SizedBox(height: 6),
              ],
            ),
          ),
          SliverList.builder(
            itemCount: _tracks.length,
            itemBuilder: (context, i) => _row(context, i),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loadingMore)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (_moreFailed)
                  Center(
                    child: TextButton(
                      onPressed: _loadMore,
                      child: Text(S.tryAgain),
                    ),
                  ),
                if (_page.stats.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                    child: Text(
                      _page.stats.join(' · '),
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ),
                for (final shelf in _page.shelves) MusicShelfView(shelf: shelf),
                SizedBox(height: HomeShell.bottomInsetOf(context) + 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _description(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: GestureDetector(
        onTap: () => setState(() => _open = !_open),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child: Text(
            _page.description!,
            maxLines: _open ? null : 3,
            overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
            style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    final track = _tracks[i];
    final p = context.palette;
    return TrackTile(
      track: track,
      // The playlist plays on from the song touched, as in the library
      onTap: () => playFrom(context, _tracks, i),
      // An album's songs are numbered and all by the same artist, so the artist is only said when it is another
      dense: _isAlbum,
      leading: _isAlbum
          ? SizedBox(
              width: 30,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.textSecondary),
              ),
            )
          : null,
      subtitle: _isAlbum
          ? (track.artist == _page.owner ? (track.stats ?? '') : track.artist)
          : null,
      trailing: TrackMenu(
        track: track,
        onAdd: () => queueTrack(context, track),
        onPlayNext: () => queueTrack(context, track, playNext: true),
      ),
    );
  }
}
