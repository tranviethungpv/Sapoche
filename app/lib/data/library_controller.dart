import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';
import 'song_key.dart';

/// The songs a person keeps: the ones they liked, what they heard, and their playlists. The truth is kept on the native side
/// (the playback service writes the history); this holds a copy for the screens and updates it when told.
class LibraryController extends ChangeNotifier {
  LibraryController(this._backend);

  final Backend _backend;
  StreamSubscription<BackendEvent>? _subscription;

  /// Every song liked, as it was: a song and its video can both be there.
  List<Track> _liked = const [];

  /// The liked songs once each, for the screens.
  List<Track> _likedSongs = const [];
  Map<String, List<Track>> _likedByKey = const {};
  List<HistoryEntry> _recent = const [];
  List<SavedPlaylist> _playlists = const [];
  List<Track> _forYou = const [];
  List<DownloadEntry> _downloads = const [];
  Map<String, DownloadState> _downloadStates = const {};

  /// Songs of the playlists that were opened, kept up to date while they are.
  final _items = <int, List<Track>>{};

  /// Liked songs, the most recently liked first, a song that was liked as audio and as video only once.
  List<Track> get liked => _likedSongs;

  /// What was heard, the most recent first, a song heard as audio and as video only once.
  List<HistoryEntry> get recent => _recent;

  /// The person's playlists, the one changed last first.
  List<SavedPlaylist> get playlists => _playlists;

  /// Songs on the list of downloads, what is on the phone first.
  List<DownloadEntry> get downloads => _downloads;

  /// Where a song stands, or null when it was never asked for.
  DownloadState? downloadState(String videoId) => _downloadStates[videoId];

  /// Songs to offer, from what was kept: there at once, with or without a network.
  List<Track> get forYou => _forYou;

  /// The songs of a playlist that [openPlaylist] loaded.
  List<Track> playlistTracks(int id) => _items[id] ?? const [];

  /// The song is liked, in either of its forms: the audio release or a video of it.
  bool isLikedSong(Track track) =>
      _likedByKey[songKey(track.title, track.artist)]?.any(
        (t) => sameSong(t, track),
      ) ??
      false;

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
      final forYou = await _backend.forYou();
      final downloads = await _backend.downloads();
      final items = <int, List<Track>>{};
      for (final id in _items.keys.toList()) {
        if (playlists.any((p) => p.id == id)) {
          items[id] = await _backend.playlistTracks(id);
        }
      }
      _setLiked(liked);
      _recent = _oncePerSong(recent);
      _playlists = playlists;
      _forYou = forYou;
      _downloads = downloads;
      _downloadStates = {for (final d in downloads) d.track.videoId: d.state};
      _items
        ..clear()
        ..addAll(items);
      notifyListeners();
    } on Object {
      // Nothing to show is better than an error on every screen
    }
  }

  /// Likes the song, or takes the like back from every form of it. The heart changes at once; if the write
  /// fails it changes back.
  Future<void> toggleLike(Track track) async {
    final before = _liked;
    final wasLiked = isLikedSong(track);
    final forms = [
      for (final t in _liked)
        if (sameSong(t, track)) t,
    ];
    _setLiked(
      wasLiked
          ? [
              for (final t in _liked)
                if (!forms.contains(t)) t,
            ]
          : [track, ..._liked],
    );
    notifyListeners();
    try {
      if (wasLiked) {
        for (final form in forms) {
          await _backend.setLiked(form, false);
        }
      } else {
        await _backend.setLiked(track, true);
      }
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

  /// Asks for songs to be downloaded. Gives back false when nothing was done because the phone is on mobile
  /// data: ask the person, then call again with [allowMetered].
  Future<bool> download(List<Track> tracks, {bool allowMetered = false}) async {
    try {
      final started = await _backend.download(
        tracks,
        allowMetered: allowMetered,
      );
      if (started) await refresh();
      return started;
    } on Object catch (e) {
      _messages.add('$e');
      return true; // there is nothing to ask about
    }
  }

  Future<void> removeDownload(String videoId) =>
      _change(() => _backend.removeDownload(videoId));

  Future<void> clearDownloads() => _change(_backend.clearDownloads);

  /// What the kept songs take, for the settings; null when it cannot be read.
  Future<StorageInfo?> storage() async {
    try {
      return await _backend.storage();
    } on Object {
      return null;
    }
  }

  Future<void> clearPlayCache() => _run(_backend.clearPlayCache);
  Future<void> setCacheLimit(int mb) => _run(() => _backend.setCacheLimit(mb));
  Future<void> setAutoDownload(bool on) =>
      _run(() => _backend.setAutoDownload(on));

  /// Saves the library to a file the person picks. Null when they backed out or it failed, which is said in [messages].
  Future<BackupCounts?> exportBackup() => _file(_backend.exportBackup);

  /// Adds what a file the person picks holds; gives back how much was new.
  Future<BackupCounts?> importBackup() => _file(_backend.importBackup);

  Future<BackupCounts?> _file(Future<BackupCounts?> Function() action) async {
    try {
      return await action();
    } on BackendException catch (e) {
      _messages.add(e.message);
    } on Object catch (e) {
      _messages.add('$e');
    }
    return null;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      _messages.add('$e');
    }
  }

  /// Fetches the suggestions again, for a pull to refresh. Gives back false when that failed.
  Future<bool> refreshForYou() async {
    try {
      _forYou = await _backend.refreshSuggestions();
      notifyListeners();
      return true;
    } on Object {
      return false;
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
    _likedSongs = uniqueSongs(liked);
    _likedByKey = {};
    for (final t in liked) {
      _likedByKey.putIfAbsent(songKey(t.title, t.artist), () => []).add(t);
    }
  }

  /// [entries] with each song once, the first (most recent) staying.
  List<HistoryEntry> _oncePerSong(List<HistoryEntry> entries) {
    final kept = uniqueSongs([for (final e in entries) e.track]);
    final keep = {for (final t in kept) t.videoId};
    return [
      for (final e in entries)
        if (keep.contains(e.track.videoId)) e,
    ];
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }
}
