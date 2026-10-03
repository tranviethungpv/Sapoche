import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../data/room_controller.dart';
import '../data/song_key.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'collection_screen.dart';
import 'home_shell.dart';
import 'player/track_section.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/link_banner.dart';
import 'widgets/play_actions.dart';
import 'widgets/queue_actions.dart';
import 'widgets/shimmer.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// Search YouTube Music (or paste a link) for anything: songs, videos, albums, artists, playlists, profiles and
/// podcasts. While the person types, a few completions and what is found so far are listed under one another; once
/// they press search, the filters appear, to keep one kind of result.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.focusNode});

  /// The search field's focus, for the shell to put the cursor in it (from the sidebar, or with the `/` key).
  final FocusNode? focusNode;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _Phase { idle, loading, results, failed }

class _SearchPageState extends State<SearchPage> {
  /// How many completions are offered.
  static const _completions = 3;

  static const _capsule = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(999)),
    borderSide: BorderSide.none,
  );

  final _field = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  _Phase _phase = _Phase.idle;

  /// The words the results on screen were asked for.
  String? _asked;

  /// Set once the person pressed search or picked a completion: only then are the filters offered.
  bool _submitted = false;

  /// The filters YouTube Music offers for the words asked, the one in use (null for everything, the top results) and
  /// whether it is the extra one for ordinary YouTube videos.
  List<SearchChip> _chips = const [];
  String? _params;
  bool _youtube = false;

  SearchItem? _top;
  List<SearchItem> _items = const [];

  /// Where the results after these are asked for.
  String? _more;
  bool _loadingMore = false;

  /// Guards against a slow answer for an old search replacing a newer one.
  int _generation = 0;

  /// How YouTube would complete what is typed, and the timer that waits for a pause before asking.
  List<String> _suggestions = const [];
  Timer? _suggestTimer;
  int _suggestGeneration = 0;

  /// The words of the search on screen, remembered once the person does something with its results.
  String? _lastQuery;

  RoomController get _room => AppScope.roomOf(context);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_more != null && !_loadingMore && _scroll.position.extentAfter < 600) {
      _loadMore();
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    if (text.trim().isEmpty) {
      _generation++;
      _suggestGeneration++;
      setState(() {
        _phase = _Phase.idle;
        _asked = null;
        _submitted = false;
        _top = null;
        _items = const [];
        _more = null;
        _suggestions = const [];
      });
      return;
    }
    // New words start from everything again, with the filters out of sight until search is pressed
    setState(() {
      _submitted = false;
      _params = null;
      _youtube = false;
    });
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
    setState(() => _suggestions = found.take(_completions).toList());
  }

  /// Search was pressed, or a completion or an earlier search was picked: look now, and offer the filters.
  void _submit(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _suggestGeneration++;
    FocusScope.of(context).unfocus();
    if (!text.contains('youtu')) AppScope.of(context).searches.add(text);
    final same = _asked == text && _params == null && !_youtube;
    setState(() {
      _submitted = true;
      _suggestions = const [];
    });
    // What is on screen, or on its way, is for these words already (a link is still gone to)
    if (!same || _phase == _Phase.failed || text.contains('youtu')) {
      _run(text, open: true);
    }
  }

  /// A completion or an earlier search was picked.
  void _pick(String term) {
    _field.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    setState(() {
      _params = null;
      _youtube = false;
    });
    _submit(term);
  }

  /// Looks for [query] in the way the filters say. With [open], a link to a playlist is opened as the page it is.
  Future<void> _run(String query, {bool open = false}) async {
    final generation = ++_generation;
    _lastQuery = query.contains('youtu') ? null : query;
    _asked = query;
    setState(() {
      _phase = _Phase.loading;
      _loadingMore = false;
    });
    try {
      final link = query.contains('youtu') ? await _room.lookup(query) : null;
      if (!mounted || generation != _generation) return;
      if (link != null) {
        _show(
          items: [for (final t in link.tracks) _videoItem(t)],
          chips: const [],
        );
        final list = RegExp(r'[?&]list=([\w-]+)').firstMatch(query)?[1];
        if (open && link.playlistTitle != null && list != null) {
          openCollection(context, id: list, title: link.playlistTitle);
        }
        return;
      }
      if (_youtube) {
        final found = await _room.search(query, songsOnly: false);
        if (!mounted || generation != _generation) return;
        // A song and its official video come up side by side: one row is enough
        _show(items: [for (final t in uniqueSongs(found)) _videoItem(t)]);
        return;
      }
      final found = await AppScope.of(context).music
          .searchPage(query, params: _params);
      if (!mounted || generation != _generation) return;
      _show(
        top: found.top,
        items: found.items,
        // The filters are those of the search for everything; a filtered answer repeats them
        chips: _params == null ? found.chips : null,
        more: found.more,
      );
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  void _show({
    SearchItem? top,
    required List<SearchItem> items,
    List<SearchChip>? chips,
    String? more,
  }) => setState(() {
    _top = top;
    _items = items;
    _more = more;
    if (chips != null) _chips = chips;
    _phase = _Phase.results;
  });

  /// An ordinary YouTube video, which is what the search of YouTube itself and a pasted link give.
  SearchItem _videoItem(Track track) => SearchItem(
    kind: 'video',
    id: track.videoId,
    title: track.title,
    thumb: track.thumb,
    track: track,
  );

  Future<void> _loadMore() async {
    final token = _more;
    if (token == null || _loadingMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final next = await AppScope.of(context).music.searchMore(token);
      if (!mounted || generation != _generation) return;
      final known = {for (final i in _items) '${i.kind} ${i.id}'};
      setState(() {
        _items = [
          ..._items,
          for (final i in next.items)
            if (!known.contains('${i.kind} ${i.id}')) i,
        ];
        _more = next.more;
        _loadingMore = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      // The results so far stay; scrolling again tries again
      setState(() => _loadingMore = false);
    }
  }

  /// A filter was chosen: [params] for one kind of result, none for everything, or the one for YouTube itself.
  void _choose({String? params, bool youtube = false}) {
    if (_params == params && _youtube == youtube) return;
    HapticFeedback.selectionClick();
    setState(() {
      _params = params;
      _youtube = youtube;
      _top = null;
      _items = const [];
      _more = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final text = _field.text.trim();
    if (text.isNotEmpty) _run(text);
  }

  /// Remembers the words of the search once the person does something with what it found.
  void _remember() {
    final query = _lastQuery;
    if (query != null) AppScope.of(context).searches.add(query);
  }

  /// A touch on a result: what plays plays (or is queued, in a room), the rest opens its page.
  void _open(SearchItem item) {
    _remember();
    final track = item.track;
    if (track != null) {
      playNow(context, track);
      return;
    }
    switch (item.kind) {
      case 'artist' || 'profile':
        openArtist(context, item.id);
      default:
        openCollection(
          context,
          id: item.id,
          title: item.title,
          thumb: item.thumb,
        );
    }
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
          return _Message(
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
            padding: EdgeInsets.only(bottom: HomeShell.bottomInsetOf(context)),
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
                        child: Text(S.clear),
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
                    onTap: () => playNow(context, track),
                    trailing: TrackMenu(
                      track: track,
                      onAdd: () => queueTrack(context, track),
                      onPlayNext: () =>
                          queueTrack(context, track, playNext: true),
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
                focusNode: widget.focusNode,
                onChanged: _onChanged,
                onSubmitted: _submit,
                textInputAction: TextInputAction.search,
                style: theme.bodyLarge,
                // A see-through capsule on the page's backdrop, like the other things that sit on it
                decoration: InputDecoration(
                  filled: true,
                  fillColor: context.palette.veil,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  border: _capsule,
                  enabledBorder: _capsule,
                  focusedBorder: _capsule.copyWith(
                    borderSide: BorderSide(
                      color: context.palette.primary,
                      width: 1.5,
                    ),
                  ),
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
          // The filters are only offered once search was pressed
          if (_submitted && _phase != _Phase.idle) _filters(context),
          ListenableBuilder(
            listenable: _room,
            builder: (context, _) => LinkBanner(link: _room.snapshot.link),
          ),
          Expanded(child: _content(context)),
        ],
      ),
    );
  }

  /// "Top results", songs, the one for ordinary YouTube videos, and the other filters YouTube Music gives for these
  /// words: songs and videos are what most searches are for, so they come first.
  Widget _filters(BuildContext context) {
    Widget chip(SearchChip chip) => Padding(
      padding: const EdgeInsets.only(left: 8),
      child: _FilterChip(
        label: S.searchChip(chip.label),
        selected: _params == chip.params && !_youtube,
        onTap: () => _choose(params: chip.params),
      ),
    );
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        children: [
          _FilterChip(
            label: S.searchTop,
            selected: _params == null && !_youtube,
            onTap: _choose,
          ),
          for (final c in _chips.where((c) => c.label == 'Songs')) chip(c),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _FilterChip(
              label: S.searchYouTube,
              selected: _youtube,
              onTap: () => _choose(youtube: true),
            ),
          ),
          for (final c in _chips.where((c) => c.label != 'Songs')) chip(c),
        ],
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _field.text = text;
    // A pasted link is meant to be gone to
    _onChanged(text);
    _submit(text);
  }

  /// The completions, then what was found: one list that scrolls.
  List<Widget> _completionRows() => [
    if (!_submitted && _field.text.trim().isNotEmpty)
      for (final term in _suggestions)
        _CompletionRow(term: term, onTap: () => _pick(term)),
  ];

  Widget _content(BuildContext context) {
    final bottom = HomeShell.bottomInsetOf(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (_phase) {
        // Before the first answer, what is typed has its completions only
        _Phase.idle when _field.text.trim().isNotEmpty => ListView(
          key: const ValueKey('typing'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: _completionRows(),
        ),
        _Phase.idle => _idle(context),
        _Phase.loading => Column(
          key: const ValueKey('loading'),
          children: [
            ..._completionRows(),
            const Expanded(child: SkeletonList()),
          ],
        ),
        _Phase.failed => _Message(
          key: ValueKey('failed'),
          icon: Icons.wifi_off_rounded,
          title: S.searchFailed,
        ),
        _Phase.results when _items.isEmpty && _top == null => Column(
          key: const ValueKey('empty'),
          children: [
            ..._completionRows(),
            Expanded(
              child: _Message(
                icon: Icons.music_off_rounded,
                title: S.noResults,
              ),
            ),
          ],
        ),
        _Phase.results => ListView(
          key: const ValueKey('results'),
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(top: 4, bottom: bottom),
          children: [
            ..._completionRows(),
            if (_top != null) ...[
              SectionHeading(S.topResult),
              _ResultRow(item: _top!, onTap: _open, labelled: true),
              if (_items.isNotEmpty) const SizedBox(height: 6),
            ],
            for (final item in _items)
              _ResultRow(
                item: item,
                onTap: _open,
                labelled: _params == null && !_youtube,
              ),
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
          ],
        ),
      },
    );
  }
}

/// One way YouTube would complete what is typed.
class _CompletionRow extends StatelessWidget {
  const _CompletionRow({required this.term, required this.onTap});

  final String term;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 20, color: p.textTertiary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                term,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            Icon(Icons.north_west_rounded, size: 18, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// One result: what plays has the usual row of a song, the rest (an album, an artist, a playlist) has a row that opens
/// its page.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.item,
    required this.onTap,
    this.labelled = false,
  });

  final SearchItem item;
  final ValueChanged<SearchItem> onTap;

  /// Says what kind of result it is, as the list of everything has all kinds mixed.
  final bool labelled;

  /// What kind of result it is, in the language of the app.
  String get _kind => switch (item.kind) {
    'song' => S.kindSong,
    'video' => S.kindVideo,
    'episode' => S.kindEpisode,
    'artist' => S.infoArtist,
    'profile' => S.kindProfile,
    'album' => S.collectionKind(item.label ?? 'Album'),
    _ => S.collectionKind(item.label ?? 'Playlist'),
  };

  /// The line under a song, video or episode: who it is by and how many watched it.
  String? get _byline {
    final track = item.track;
    if (track == null) return null;
    if (item.kind == 'episode') return item.subtitle;
    final stats = track is MusicTrack ? track.stats : null;
    return [
      track.artist,
      if (stats != null && stats.isNotEmpty) stats,
    ].where((e) => e.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final track = item.track;
    if (track != null) {
      final line = _byline;
      return TrackTile(
        track: track,
        subtitle: labelled ? [_kind, ?line].join(' · ') : line,
        onTap: () => onTap(item),
        trailing: TrackMenu(
          track: track,
          onAdd: () => queueTrack(context, track),
          onPlayNext: () => queueTrack(context, track, playNext: true),
        ),
      );
    }
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final round = item.kind == 'artist' || item.kind == 'profile';
    // The same picture and the same height as the row of a song, so all kinds of result line up
    const size = 54.0;
    final line = [
      _kind,
      ?(track == null ? item.subtitle : _byline),
    ].where((e) => e.isNotEmpty).join(' · ');
    return InkWell(
      onTap: () => onTap(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        child: Row(
          children: [
            Artwork(
              url: item.thumb,
              size: size,
              radius: round ? size / 2 : SapocheTheme.artworkRadius,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            // As wide as the menu of a song, so the end of every row is in the same place
            SizedBox(
              width: 48,
              child: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
            ),
          ],
        ),
      ),
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
        padding: EdgeInsets.fromLTRB(
          40,
          0,
          40,
          HomeShell.bottomInsetOf(context),
        ),
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

/// A pill that narrows what a search looks for: a fixed height, with the words in the middle of it.
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
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 34,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? p.primary : p.veil,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          // The font's own spacing above and below the letters is uneven: one height for the line, centred
          strutStyle: const StrutStyle(forceStrutHeight: true, height: 1),
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(fontSize: 13, color: selected ? p.onPrimary : p.text),
        ),
      ),
    );
  }
}
