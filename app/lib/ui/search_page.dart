import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/link_banner.dart';
import 'widgets/track_tile.dart';

/// Search YouTube (or paste a link) and put songs on the room's queue.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _Phase { idle, loading, results, failed }

class _SearchPageState extends State<SearchPage> {
  final _field = TextEditingController();
  Timer? _debounce;
  _Phase _phase = _Phase.idle;
  List<Track> _results = const [];

  /// Set when the results are the songs of a pasted playlist link.
  String? _playlistTitle;

  /// Ids added during this visit, so the row shows a check instead of the plus.
  final _added = <String>{};

  /// Guards against a slow answer for an old query replacing a newer one.
  int _generation = 0;

  RoomController get _room => AppScope.roomOf(context);

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      _generation++;
      setState(() {
        _phase = _Phase.idle;
        _results = const [];
        _playlistTitle = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _run(text.trim()),
    );
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    setState(() => _phase = _Phase.loading);
    try {
      final looksLikeLink = query.contains('youtu');
      final link = looksLikeLink ? await _room.lookup(query) : null;
      final found = link?.tracks ?? await _room.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found;
        _playlistTitle = link?.playlistTitle;
        _phase = _Phase.results;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  Future<void> _add(Track track, {bool playNext = false}) => _addTracks(
    [track],
    playNext ? S.willPlayNext : S.addedToQueue,
    playNext: playNext,
  );

  Future<void> _addAll({bool playNext = false}) =>
      _addTracks(_results, S.playlistAdded, playNext: playNext);

  Future<void> _addTracks(
    List<Track> tracks,
    String confirmation, {
    required bool playNext,
  }) async {
    HapticFeedback.selectionClick();
    final ids = tracks.map((t) => t.videoId).toList();
    setState(() => _added.addAll(ids));
    if (tracks.length == 1) {
      await _room.add(tracks.single, playNext: playNext);
    } else {
      await _room.addMany(tracks, playNext: playNext);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(confirmation),
          duration: const Duration(milliseconds: 1400),
        ),
      );
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _added.removeAll(ids));
    });
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
                  if (text.trim().isNotEmpty) _run(text.trim());
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
          ListenableBuilder(
            listenable: _room,
            builder: (context, _) => LinkBanner(link: _room.snapshot.link),
          ),
          Expanded(child: _content(context)),
        ],
      ),
    );
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
        _Phase.idle => const _Message(
          key: ValueKey('idle'),
          icon: Icons.search_rounded,
          title: S.searchEmptyTitle,
          body: S.searchEmptyBody,
        ),
        _Phase.loading => const Center(
          key: ValueKey('loading'),
          child: CircularProgressIndicator(),
        ),
        _Phase.failed => const _Message(
          key: ValueKey('failed'),
          icon: Icons.wifi_off_rounded,
          title: S.searchFailed,
        ),
        _Phase.results when _results.isEmpty => const _Message(
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
                onAddAll: _addAll,
                onPlayNext: () => _addAll(playNext: true),
              );
            }
            final track = _results[index - (_playlistTitle == null ? 0 : 1)];
            return TrackTile(
              track: track,
              onTap: () => _add(track),
              trailing: _Actions(
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
  });

  final String title;
  final int count;
  final VoidCallback onAddAll;
  final VoidCallback onPlayNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.added,
    required this.onAdd,
    required this.onPlayNext,
  });

  final bool added;
  final VoidCallback onAdd;
  final VoidCallback onPlayNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
        PopupMenuButton<String>(
          icon: Icon(Icons.more_horiz_rounded, color: p.textSecondary),
          color: p.brightness == Brightness.light
              ? const Color(0xFFFFF7F9)
              : const Color(0xFF2B1F25),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          onSelected: (value) => value == 'next' ? onPlayNext() : onAdd(),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'next', child: Text(S.playNext)),
            PopupMenuItem(value: 'end', child: Text(S.addToQueue)),
          ],
        ),
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
