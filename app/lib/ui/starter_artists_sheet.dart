import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/artwork.dart';

/// "Pick a few artists you like": for a new person, whose taste is not known yet. Each artist picked puts their best
/// known song among the starter songs of the taste, and the suggestions are made again from them.
Future<void> showStarterArtists(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: context.palette.surface,
    builder: (_) => const _StarterArtists(),
  );
}

class _StarterArtists extends StatefulWidget {
  const _StarterArtists();

  @override
  State<_StarterArtists> createState() => _StarterArtistsState();
}

enum _Phase { loading, done, failed }

class _StarterArtistsState extends State<_StarterArtists> {
  /// The most artists the charts show.
  static const _cap = 30;

  final _field = TextEditingController();
  Timer? _debounce;

  /// Counts the lookups, so that an answer that comes late is not shown.
  int _generation = 0;
  _Phase _phase = _Phase.loading;
  bool _starting = false;
  List<ArtistCard> _charts = const [];
  List<ArtistCard> _found = const [];

  /// The artists picked, in the order they were picked; they stay picked while the words change.
  final _picked = <String, ArtistCard>{};

  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    unawaited(_loadCharts());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _loadCharts() async {
    final generation = ++_generation;
    try {
      final shelves = await AppScope.of(context).music.charts();
      if (!mounted || generation != _generation) return;
      final seen = <String>{};
      setState(() {
        _charts = [
          for (final shelf in shelves)
            for (final a in shelf.artists)
              if (seen.add(a.id)) a,
        ].take(_cap).toList();
        _phase = _Phase.done;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      _generation++;
      setState(() {
        _found = const [];
        _phase = _Phase.done;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(query));
  }

  /// Looks for artists by name: the filter of artists YouTube Music offers, or the artists among the first results
  /// when it offers none.
  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() => _phase = _Phase.loading);
    try {
      final music = AppScope.of(context).music;
      var results = await music.searchPage(query);
      final chip = results.chips.where((c) => c.label == 'Artists').firstOrNull;
      if (chip != null) results = await music.searchPage(query, params: chip.params);
      if (!mounted || generation != _generation) return;
      setState(() {
        _found = [
          for (final item in [?results.top, ...results.items])
            if (item.kind == 'artist') ArtistCard(id: item.id, name: item.title, subtitle: item.subtitle, thumb: item.thumb),
        ];
        _phase = _Phase.done;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  void _toggle(ArtistCard artist) => setState(() {
    if (_picked.remove(artist.id) == null) _picked[artist.id] = artist;
  });

  /// Puts the best known song of each artist picked among the starter songs, then closes and asks for new suggestions.
  Future<void> _start() async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _starting = true);
    var started = 0;
    for (final artist in _picked.values) {
      try {
        final page = await scope.music.artist(artist.id);
        final song = page.topSongs.firstOrNull;
        if (song == null) continue;
        await scope.library.setTasteMark(TasteMarks.starter, song.videoId, TasteMarks.starterLabel(song), on: true);
        started++;
      } on Object {
        continue;
      }
    }
    if (started > 0) unawaited(scope.library.refreshForYou());
    if (navigator.mounted) navigator.pop();
    if (started == 0) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.pickArtistsNothing)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) => Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: min(box.maxHeight * 0.85, box.maxHeight - keyboard),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(S.pickArtists, style: Theme.of(context).textTheme.headlineSmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('starter-field'),
                  controller: _field,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: S.pickArtistsSearch,
                    prefixIcon: Icon(Icons.search_rounded, color: p.textTertiary),
                    isDense: true,
                    filled: true,
                    fillColor: p.primary.withValues(alpha: 0.10),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(child: _content(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('starter-start'),
                    onPressed: _picked.isEmpty || _starting ? null : _start,
                    child: _starting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(S.pickArtistsStart),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final p = context.palette;
    Widget message(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.textSecondary),
        ),
      ),
    );
    final artists = _field.text.trim().isEmpty ? _charts : _found;
    return switch (_phase) {
      _Phase.loading => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      _Phase.failed => message(S.pickArtistsFailed),
      _Phase.done when artists.isEmpty => message(S.pickArtistsNone),
      _ => GridView.builder(
        key: const ValueKey('starter-grid'),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, childAspectRatio: 0.82),
        itemCount: artists.length,
        itemBuilder: (context, i) => _ArtistTile(
          key: ValueKey('starter-artist-${artists[i].id}'),
          artist: artists[i],
          picked: _picked.containsKey(artists[i].id),
          onTap: () => _toggle(artists[i]),
        ),
      ),
    };
  }
}

/// A round picture and a name, with a check on the picture once the artist is picked.
class _ArtistTile extends StatelessWidget {
  const _ArtistTile({super.key, required this.artist, required this.picked, required this.onTap});

  final ArtistCard artist;
  final bool picked;
  final VoidCallback onTap;

  static const _size = 84.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: picked,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SapocheTheme.artworkRadius),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Artwork(url: artist.thumb, size: _size, radius: _size / 2),
                  if (picked)
                    Container(
                      width: _size,
                      height: _size,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: p.primary.withValues(alpha: 0.55)),
                      child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                artist.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
