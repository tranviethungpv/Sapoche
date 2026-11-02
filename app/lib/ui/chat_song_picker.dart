import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/chat_extra.dart';
import '../data/library_controller.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/track_tile.dart';

/// "Send a song": a sheet to pick the song to put in the chat. It opens on the song playing, the liked ones and the ones
/// heard lately, and searches YouTube Music as words are typed. Gives the song picked, or null if it was closed.
Future<Track?> showSongPicker(BuildContext context) {
  final scope = AppScope.of(context);
  return showModalBottomSheet<Track>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: context.palette.surface,
    builder: (_) => _SongPicker(room: scope.room, library: scope.library),
  );
}

class _SongPicker extends StatefulWidget {
  const _SongPicker({required this.room, required this.library});

  final RoomController room;
  final LibraryController library;

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

enum _Phase { idle, loading, done, failed }

class _SongPickerState extends State<_SongPicker> {
  /// How many liked and recently heard songs the sheet opens with.
  static const _liked = 4;
  static const _recent = 5;
  static const _completions = 4;

  final _field = TextEditingController();
  Timer? _debounce;
  Timer? _suggestTimer;

  /// Counts the searches and completions asked for, so that an answer that comes late is not shown.
  int _generation = 0;
  int _suggestGeneration = 0;
  _Phase _phase = _Phase.idle;
  List<Track> _found = const [];
  List<String> _suggestions = const [];

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
    final query = text.trim();
    if (query.isEmpty) {
      _generation++;
      _suggestGeneration++;
      setState(() {
        _phase = _Phase.idle;
        _found = const [];
        _suggestions = const [];
      });
      return;
    }
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(query));
    _suggestTimer = Timer(const Duration(milliseconds: 250), () => _suggest(query));
  }

  Future<void> _suggest(String query) async {
    final generation = ++_suggestGeneration;
    final found = await widget.room.suggest(query);
    if (!mounted || generation != _suggestGeneration) return;
    setState(() => _suggestions = found.take(_completions).toList());
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() => _phase = _Phase.loading);
    try {
      final found = await widget.room.search(query, songsOnly: true);
      if (!mounted || generation != _generation) return;
      setState(() {
        _found = _sendable(found);
        _phase = _Phase.done;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  /// A completion was picked: look for it at once.
  void _pick(String term) {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _suggestGeneration++;
    _field.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    setState(() => _suggestions = const []);
    FocusScope.of(context).unfocus();
    _search(term);
  }

  /// The songs of [tracks] that can go in the chat: those with the id of a video of YouTube, no file of this phone.
  static List<Track> _sendable(Iterable<Track> tracks) => [
    for (final t in tracks)
      if (SongExtra.isVideoId(t.videoId)) t,
  ];

  /// What the sheet shows before anything is typed: the song playing, then liked, then heard lately, a song only once.
  List<(String, List<Track>)> _starting() {
    final seen = <String>{};
    List<Track> take(Iterable<Track> tracks, int count) {
      final out = <Track>[];
      for (final t in _sendable(tracks)) {
        if (out.length >= count) break;
        if (seen.add(t.videoId)) out.add(t);
      }
      return out;
    }

    final current = widget.room.snapshot.current;
    final now = take([?current], 1);
    final liked = take(widget.library.liked, _liked);
    final recent = take([for (final e in widget.library.recent) e.track], _recent);
    return [
      if (now.isNotEmpty) (S.nowPlaying, now),
      if (liked.isNotEmpty) (S.likedSongs, liked),
      if (recent.isNotEmpty) (S.recentlyPlayed, recent),
    ];
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
                child: Text(S.chatAddSong, style: Theme.of(context).textTheme.headlineSmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('song-picker-field'),
                  controller: _field,
                  autofocus: false,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: (text) => text.trim().isEmpty ? null : _pick(text.trim()),
                  decoration: InputDecoration(
                    hintText: S.chatSongSearchHint,
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    Widget message(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.bodyMedium?.copyWith(color: p.textSecondary),
        ),
      ),
    );

    if (_field.text.trim().isEmpty) {
      final sections = _starting();
      if (sections.isEmpty) return message(S.chatSongEmpty);
      return ListView(
        key: const ValueKey('song-picker-start'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          for (final (title, tracks) in sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(title, style: theme.titleSmall?.copyWith(color: p.textSecondary)),
            ),
            for (final t in tracks) _row(t),
          ],
        ],
      );
    }
    return ListView(
      key: const ValueKey('song-picker-results'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final term in _suggestions)
          ListTile(
            key: ValueKey('song-picker-term-$term'),
            dense: true,
            leading: Icon(Icons.search_rounded, color: p.textTertiary),
            title: Text(term),
            onTap: () => _pick(term),
          ),
        switch (_phase) {
          _Phase.loading => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          _Phase.failed => SizedBox(height: 120, child: message(S.chatSongSearchFailed)),
          _Phase.done when _found.isEmpty => SizedBox(height: 120, child: message(S.chatSongNoResults)),
          _ => const SizedBox.shrink(),
        },
        if (_phase == _Phase.done)
          for (final t in _found) _row(t),
      ],
    );
  }

  Widget _row(Track track) => TrackTile(
    key: ValueKey('song-picker-${track.videoId}'),
    track: track,
    onTap: () => Navigator.of(context).pop(track),
    // No heart here: the song is picked, not kept
    trailing: track.durMs > 0
        ? Text(formatDuration(track.durMs), style: Theme.of(context).textTheme.bodySmall)
        : const SizedBox.shrink(),
  );
}
