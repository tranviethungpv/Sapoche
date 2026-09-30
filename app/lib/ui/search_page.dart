import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/link_banner.dart';
import 'widgets/shimmer.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// Search YouTube (or paste a link) and put songs on the room's queue.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _Phase { idle, loading, results, failed }

/// What a search looks for.
enum _Filter { videos, songs, playlists }

class _SearchPageState extends State<SearchPage> {
  final _field = TextEditingController();
  Timer? _debounce;
  _Phase _phase = _Phase.idle;
  List<Track> _results = const [];

  /// Set when the results are the songs of a pasted playlist link.
  String? _playlistTitle;

  /// Ids added during this visit, so the row shows a check instead of the plus.
  final _added = <String>{};

  _Filter _filter = _Filter.videos;

  /// Playlists found by the last search while looking for playlists.
  List<PlaylistRef> _playlists = const [];

  /// The songs on screen belong to a playlist that was picked from [_playlists], so there is a way back.
  bool _fromPlaylists = false;

  /// Showing the list of playlists, as opposed to the songs of one.
  bool get _showingPlaylists =>
      _filter == _Filter.playlists && _playlistTitle == null;

  /// Guards against a slow answer for an old query replacing a newer one.
  int _generation = 0;

  /// How YouTube would complete what is typed, and the timer that waits for a pause before asking.
  List<String> _suggestions = const [];
  Timer? _suggestTimer;
  int _suggestGeneration = 0;

  /// The words of the search on screen, remembered once the person does something with its results.
  String? _lastQuery;

  RoomController get _room => AppScope.roomOf(context);

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    if (text.trim().isEmpty) {
      _generation++;
      _suggestGeneration++;
      setState(() {
        _phase = _Phase.idle;
        _results = const [];
        _playlistTitle = null;
        _suggestions = const [];
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _run(text.trim()),
    );
    // A link needs no completing
    if (!text.contains('youtu')) {
      _suggestTimer = Timer(
        const Duration(milliseconds: 250),
        () => _suggest(text.trim()),
      );
    }
  }

  Future<void> _suggest(String text) async {
    final generation = ++_suggestGeneration;
    final found = await _room.suggest(text);
    if (!mounted || generation != _suggestGeneration) return;
    setState(() => _suggestions = found);
  }

  /// A completion was picked: search for it now.
  void _pick(String term) {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _field.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    FocusScope.of(context).unfocus();
    setState(() => _suggestions = const []);
    AppScope.of(context).searches.add(term);
    _run(term);
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    _lastQuery = query.contains('youtu') ? null : query;
    setState(() => _phase = _Phase.loading);
    try {
      final looksLikeLink = query.contains('youtu');
      final link = looksLikeLink ? await _room.lookup(query) : null;
      if (link == null && _filter == _Filter.playlists) {
        final lists = await _room.searchPlaylists(query);
        if (!mounted || generation != _generation) return;
        setState(() {
          _playlists = lists;
          _results = const [];
          _playlistTitle = null;
          _fromPlaylists = false;
          _phase = _Phase.results;
        });
        return;
      }
      final found =
          link?.tracks ??
          await _room.search(query, songsOnly: _filter == _Filter.songs);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found;
        _playlistTitle = link?.playlistTitle;
        _playlists = const [];
        _fromPlaylists = false;
        _phase = _Phase.results;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  /// Fetches the songs of a playlist from the list of playlists.
  Future<void> _openPlaylist(PlaylistRef playlist) async {
    final generation = ++_generation;
    setState(() => _phase = _Phase.loading);
    try {
      final link = await _room.lookup(
        'https://www.youtube.com/playlist?list=${playlist.id}',
      );
      if (link == null) throw StateError('not a playlist');
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = link.tracks;
        _playlistTitle = link.playlistTitle ?? playlist.title;
        _fromPlaylists = true;
        _phase = _Phase.results;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      // Stay on the list of playlists
      setState(() => _phase = _Phase.results);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text(S.playlistFailed)));
    }
  }

  void _closePlaylist() => setState(() {
    _results = const [];
    _playlistTitle = null;
    _fromPlaylists = false;
  });

  Future<void> _add(Track track, {bool playNext = false}) => _addTracks(
    [track],
    playNext ? S.willPlayNext : S.addedToQueue,
    playNext: playNext,
  );

  /// Keeps the songs of the playlist that is showing as a playlist of the person's own.
  Future<void> _saveAsPlaylist() async {
    final id = await AppScope.of(context).library
        .createPlaylist(_playlistTitle ?? '', _results);
    if (id == null || !mounted) return;
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(S.playlistSaved)));
  }

  Future<void> _addAll({bool playNext = false}) =>
      _addTracks(_results, S.playlistAdded, playNext: playNext);

  Future<void> _addTracks(
    List<Track> tracks,
    String confirmation, {
    required bool playNext,
  }) async {
    HapticFeedback.selectionClick();
    final query = _lastQuery;
    if (query != null) AppScope.of(context).searches.add(query);
    // What is waiting in the queue is not added twice
    final fresh = _room.snapshot.fresh(tracks);
    final ids = fresh.map((t) => t.videoId).toList();
    setState(() => _added.addAll(ids));
    if (fresh.length == 1) {
      await _room.add(fresh.single, playNext: playNext);
    } else if (fresh.isNotEmpty) {
      await _room.addMany(fresh, playNext: playNext);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            fresh.isEmpty
                ? S.alreadyInQueue
                : fresh.length < tracks.length
                ? S.addedSkipped(fresh.length, tracks.length - fresh.length)
                : confirmation,
          ),
          duration: const Duration(milliseconds: 1400),
        ),
      );
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _added.removeAll(ids));
    });
  }

  /// Nothing typed: what was searched for lately and songs to try, or a hint when there is neither.
  Widget _idle(BuildContext context) {
    final model = AppScope.of(context);
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([model.library, model.searches]),
      builder: (context, _) {
        final terms = model.searches.terms;
        final songs = model.library.forYou;
        if (terms.isEmpty && songs.isEmpty) {
          return const _Message(
            key: ValueKey('idle'),
            icon: Icons.search_rounded,
            title: S.searchEmptyTitle,
            body: S.searchEmptyBody,
          );
        }
        return RefreshIndicator(
          key: const ValueKey('idle'),
          onRefresh: model.library.refreshForYou,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: HomeShell.bottomInset),
            children: [
              if (terms.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(S.recentSearches, style: theme.titleMedium),
                      ),
                      TextButton(
                        onPressed: model.searches.clear,
                        child: const Text(S.clear),
                      ),
                    ],
                  ),
                ),
                for (final term in terms)
                  InkWell(
                    onTap: () => _pick(term),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
                      child: Row(
                        children: [
                          Icon(Icons.history_rounded, color: p.textTertiary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              term,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.bodyLarge,
                            ),
                          ),
                          IconButton(
                            onPressed: () => model.searches.remove(term),
                            tooltip: S.remove,
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: p.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (songs.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text(S.forYou, style: theme.titleMedium),
                ),
                for (final track in songs)
                  TrackTile(
                    track: track,
                    onTap: () => _add(track),
                    trailing: _Actions(
                      track: track,
                      added: _added.contains(track.videoId),
                      onAdd: () => _add(track),
                      onPlayNext: () => _add(track, playNext: true),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Text(S.tabSearch, style: theme.headlineLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListenableBuilder(
              listenable: _field,
              builder: (context, _) => TextField(
                controller: _field,
                onChanged: _onChanged,
                onSubmitted: (text) {
                  _debounce?.cancel();
                  if (text.trim().isEmpty) return;
                  if (!text.contains('youtu')) {
                    AppScope.of(context).searches.add(text);
                  }
                  _run(text.trim());
                },
                textInputAction: TextInputAction.search,
                style: theme.bodyLarge,
                decoration: InputDecoration(
                  hintText: S.searchHint,
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: context.palette.textTertiary,
                  ),
                  suffixIcon: _field.text.isEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.content_paste_rounded,
                            color: context.palette.textTertiary,
                          ),
                          onPressed: _paste,
                        )
                      : IconButton(
                          icon: Icon(
                            Icons.cancel_rounded,
                            color: context.palette.textTertiary,
                          ),
                          onPressed: () {
                            _field.clear();
                            _onChanged('');
                          },
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                for (final (filter, label) in const [
                  (_Filter.videos, S.filterVideos),
                  (_Filter.songs, S.filterSongs),
                  (_Filter.playlists, S.filterPlaylists),
                ]) ...[
                  _FilterChip(
                    label: label,
                    selected: _filter == filter,
                    onTap: () => _setFilter(filter),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          if (_suggestions.isNotEmpty && _field.text.trim().isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _FilterChip(
                  label: _suggestions[i],
                  selected: false,
                  onTap: () => _pick(_suggestions[i]),
                ),
              ),
            ),
          ListenableBuilder(
            listenable: _room,
            builder: (context, _) => LinkBanner(link: _room.snapshot.link),
          ),
          Expanded(child: _content(context)),
        ],
      ),
    );
  }

  void _setFilter(_Filter value) {
    if (_filter == value) return;
    setState(() {
      _filter = value;
      _results = const [];
      _playlists = const [];
      _playlistTitle = null;
      _fromPlaylists = false;
    });
    final text = _field.text.trim();
    if (text.isNotEmpty) _run(text);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _field.text = text;
    _onChanged(text);
  }

  Widget _content(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (_phase) {
        _Phase.idle => _idle(context),
        _Phase.loading => const SkeletonList(key: ValueKey('loading')),
        _Phase.failed => const _Message(
          key: ValueKey('failed'),
          icon: Icons.wifi_off_rounded,
          title: S.searchFailed,
        ),
        _Phase.results when _showingPlaylists && _playlists.isNotEmpty =>
          ListView.builder(
            key: const ValueKey('playlists'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(
              top: 4,
              bottom: HomeShell.bottomInset,
            ),
            itemCount: _playlists.length,
            itemBuilder: (context, i) => _PlaylistRow(
              playlist: _playlists[i],
              onTap: () => _openPlaylist(_playlists[i]),
            ),
          ),
        _Phase.results when _showingPlaylists || _results.isEmpty =>
          const _Message(
            key: ValueKey('empty'),
            icon: Icons.music_off_rounded,
            title: S.noResults,
          ),
        _Phase.results => ListView.builder(
          key: const ValueKey('results'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(top: 4, bottom: HomeShell.bottomInset),
          itemCount: _results.length + (_playlistTitle == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (_playlistTitle != null && index == 0) {
              return _PlaylistHeader(
                title: _playlistTitle!,
                count: _results.length,
                onBack: _fromPlaylists ? _closePlaylist : null,
                onAddAll: _addAll,
                onPlayNext: () => _addAll(playNext: true),
                onSave: _saveAsPlaylist,
              );
            }
            final track = _results[index - (_playlistTitle == null ? 0 : 1)];
            return TrackTile(
              track: track,
              onTap: () => _add(track),
              trailing: _Actions(
                track: track,
                added: _added.contains(track.videoId),
                onAdd: () => _add(track),
                onPlayNext: () => _add(track, playNext: true),
              ),
            );
          },
        ),
      },
    );
  }
}

/// Top of a playlist's songs: what it is and how to add all of it.
class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({
    required this.title,
    required this.count,
    required this.onAddAll,
    required this.onPlayNext,
    required this.onSave,
    this.onBack,
  });

  final String title;
  final int count;

  /// Set when the playlist was picked from a list of playlists.
  final VoidCallback? onBack;
  final VoidCallback onAddAll;
  final VoidCallback onPlayNext;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onBack != null)
            TextButton.icon(
              onPressed: onBack,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 14),
              label: const Text(S.backToPlaylists),
            ),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.titleLarge,
          ),
          const SizedBox(height: 2),
          Text(
            S.playlistSongs(count),
            style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAddAll,
                  icon: const Icon(Icons.playlist_add_rounded),
                  label: const Text(S.addAll),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: onPlayNext,
                  child: const Text(S.playNext),
                ),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text(S.saveAsPlaylist),
          ),
        ],
      ),
    );
  }
}

/// One playlist in the results: tap to see its songs.
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlist, required this.onTap});

  final PlaylistRef playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        child: Row(
          children: [
            Artwork(url: playlist.thumb, size: 54),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    S.playlistBy(playlist.uploader, playlist.count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.track,
    required this.added,
    required this.onAdd,
    required this.onPlayNext,
  });

  final Track track;
  final bool added;
  final VoidCallback onAdd;
  final VoidCallback onPlayNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final room = AppScope.roomOf(context);
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) =>
          _row(p, added || room.snapshot.isQueued(track.videoId)),
    );
  }

  Widget _row(Palette p, bool added) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: added
              ? Icon(
                  Icons.check_circle_rounded,
                  key: const ValueKey('done'),
                  color: p.success,
                  size: 30,
                )
              : IconButton.filledTonal(
                  key: const ValueKey('add'),
                  onPressed: onAdd,
                  style: IconButton.styleFrom(
                    backgroundColor: p.primaryContainer,
                    foregroundColor: p.onPrimaryContainer,
                    fixedSize: const Size(36, 36),
                  ),
                  iconSize: 20,
                  icon: const Icon(Icons.add_rounded),
                ),
        ),
        TrackMenu(track: track, onAdd: onAdd, onPlayNext: onPlayNext),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    this.body,
  });

  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, HomeShell.bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: p.primary.withValues(alpha: 0.55)),
            const SizedBox(height: 14),
            Text(title, style: theme.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body!,
                style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A pill that narrows what a search looks for.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? p.primary : p.outline),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? p.onPrimaryContainer : p.textSecondary,
          ),
        ),
      ),
    );
  }
}
