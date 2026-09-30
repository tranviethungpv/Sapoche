import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';

/// The songs a person keeps: the ones they liked, what they heard, and their playlists. The truth is kept on the native side
/// (the playback service writes the history); this holds a copy for the screens and updates it when told.
class LibraryController extends ChangeNotifier {
  LibraryController(this._backend);

  final Backend _backend;
  StreamSubscription<BackendEvent>? _subscription;

  List<Track> _liked = const [];
  Set<String> _likedIds = const {};
  List<HistoryEntry> _recent = const [];
  List<SavedPlaylist> _playlists = const [];

  /// Songs of the playlists that were opened, kept up to date while they are.
  final _items = <int, List<Track>>{};

  /// Liked songs, the most recently liked first.
  List<Track> get liked => _liked;
  List<HistoryEntry> get recent => _recent;

  /// The person's playlists, the one changed last first.
  List<SavedPlaylist> get playlists => _playlists;

  /// The songs of a playlist that [openPlaylist] loaded.
  List<Track> playlistTracks(int id) => _items[id] ?? const [];

  bool isLiked(String videoId) => _likedIds.contains(videoId);

  final _messages = StreamController<String>.broadcast();

  /// Things that went wrong, for a snackbar.
  Stream<String> get messages => _messages.stream;

  Future<void> start() async {
    _subscription = _backend.events
        .where((e) => e is LibraryEvent)
        .listen((_) => refresh());
    await refresh();
  }

  /// Reads both lists again. Failures leave what is shown as it was.
  Future<void> refresh() async {
    try {
      final liked = await _backend.liked();
      final recent = await _backend.recent();
      final playlists = await _backend.playlists();
      final items = <int, List<Track>>{};
      for (final id in _items.keys.toList()) {
        if (playlists.any((p) => p.id == id)) {
          items[id] = await _backend.playlistTracks(id);
        }
      }
      _setLiked(liked);
      _recent = recent;
      _playlists = playlists;
      _items
        ..clear()
        ..addAll(items);
      notifyListeners();
    } on Object {
      // Nothing to show is better than an error on every screen
    }
  }

  /// Likes the song, or takes the like back. The heart changes at once; if the write fails it changes back.
  Future<void> toggleLike(Track track) async {
    final before = _liked;
    final wasLiked = isLiked(track.videoId);
    _setLiked(
      wasLiked
          ? [
              for (final t in _liked)
                if (t.videoId != track.videoId) t,
            ]
          : [track, ..._liked],
    );
    notifyListeners();
    try {
      await _backend.setLiked(track, !wasLiked);
    } on Object catch (e) {
      _setLiked(before);
      notifyListeners();
      _messages.add('$e');
    }
  }

  Future<void> clearHistory() async {
    final before = _recent;
    _recent = const [];
    notifyListeners();
    try {
      await _backend.clearHistory();
    } on Object catch (e) {
      _recent = before;
      notifyListeners();
      _messages.add('$e');
    }
  }

  /// Loads the songs of a playlist; from then on they follow the changes made to it.
  Future<void> openPlaylist(int id) async {
    try {
      _items[id] = await _backend.playlistTracks(id);
      notifyListeners();
    } on Object catch (e) {
      _messages.add('$e');
    }
  }

  /// Makes a playlist with [tracks] in it. Gives back its id, or null when it could not be made.
  Future<int?> createPlaylist(
    String name, [
    List<Track> tracks = const [],
  ]) async {
    try {
      final id = await _backend.createPlaylist(name, tracks);
      await refresh();
      return id;
    } on Object catch (e) {
      _messages.add('$e');
      return null;
    }
  }

  /// Adds songs to a playlist. Gives back how many were new to it.
  Future<int> addToPlaylist(int id, List<Track> tracks) async {
    try {
      final added = await _backend.addToPlaylist(id, tracks);
      await refresh();
      return added;
    } on Object catch (e) {
      _messages.add('$e');
      return 0;
    }
  }

  Future<void> renamePlaylist(int id, String name) =>
      _change(() => _backend.renamePlaylist(id, name));

  Future<void> deletePlaylist(int id) =>
      _change(() => _backend.deletePlaylist(id));

  /// Takes a song out of a playlist; it leaves the list at once.
  Future<void> removeFromPlaylist(int id, Track track) {
    final songs = _items[id];
    if (songs != null) {
      _items[id] = [
        for (final t in songs)
          if (t.videoId != track.videoId) t,
      ];
      notifyListeners();
    }
    return _change(() => _backend.removeFromPlaylist(id, track.videoId));
  }

  /// Puts the song at place [toIndex] of the playlist; the list changes at once.
  Future<void> movePlaylistItem(int id, Track track, int toIndex) {
    final songs = _items[id];
    if (songs != null) {
      final moved = [...songs];
      final at = moved.indexWhere((t) => t.videoId == track.videoId);
      if (at >= 0) {
        moved.insert(toIndex.clamp(0, moved.length - 1), moved.removeAt(at));
        _items[id] = moved;
        notifyListeners();
      }
    }
    return _change(() => _backend.movePlaylistItem(id, track.videoId, toIndex));
  }

  /// Runs a write, then reads everything again so the screens show what was really stored.
  Future<void> _change(Future<void> Function() write) async {
    try {
      await write();
    } on Object catch (e) {
      _messages.add('$e');
    }
    await refresh();
  }

  void _setLiked(List<Track> liked) {
    _liked = liked;
    _likedIds = {for (final t in liked) t.videoId};
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }
}
