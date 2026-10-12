import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';
import 'music_models.dart';
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
  List<HistoryEntry> _listens = const [];
  List<SavedPlaylist> _playlists = const [];
  List<Track> _forYou = const [];
  List<SeedList> _seedLists = const [];
  List<Track> _discover = const [];
  ContextMix _context = const ContextMix();
  List<BlockedItem> _blocked = const [];
  List<DownloadEntry> _downloads = const [];
  Map<String, DownloadState> _downloadStates = const {};
  LocalStatus _localStatus = const LocalStatus();
  LocalScan _lastScan = const LocalScan();
  bool _localOpen = false;

  /// The music files on this phone. It has its own notifier, apart from the library's: the page of the music on the phone
  /// reads and scans as it opens, and telling every screen that listens to the library each time would make the home
  /// page work out all its rows again (a tenth of a second on a phone) for nothing, with the page stuttering as it opens.
  final localSongs = ValueNotifier<List<LocalSong>>(const []);

  /// Songs of the playlists that were opened, kept up to date while they are.
  final _items = <int, List<Track>>{};

  /// Liked songs, the most recently liked first, a song that was liked as audio and as video only once.
  List<Track> get liked => _likedSongs;

  /// What was heard, the most recent first, a song heard as audio and as video only once.
  List<HistoryEntry> get recent => _recent;

  /// Every recent listen with its own time, the latest first: sessions of listening are told from these.
  List<HistoryEntry> get listens => _listens;

  /// The person's playlists, the one changed last first.
  List<SavedPlaylist> get playlists => _playlists;

  /// Songs on the list of downloads, what is on the phone first.
  List<DownloadEntry> get downloads => _downloads;

  /// Where the list of the music on this phone stands.
  LocalStatus get localStatus => _localStatus;

  /// What the last reading of the music on this phone found.
  LocalScan get lastScan => _lastScan;

  /// The music files on this phone, the one added last first; read while [watchLocal] says the list is on show.
  List<LocalSong> get local => localSongs.value;

  /// The song comes from a file that is not on this phone any more.
  bool isMissing(Track track) => _localStatus.missing.contains(track.videoId);

  /// Where a song stands, or null when it was never asked for.
  DownloadState? downloadState(String videoId) => _downloadStates[videoId];

  /// Songs to offer, from what was kept: there at once, with or without a network.
  List<Track> get forYou => _forYou;

  /// The songs kept beside each of the songs the suggestions are built from.
  List<SeedList> get seedLists => _seedLists;

  /// Songs by artists the person does not know yet.
  List<Track> get discover => _discover;

  /// The mix for this time of day; without songs until enough was heard at this hour.
  ContextMix get context => _context;

  /// The songs and artists the person asked not to be offered, the latest first.
  List<BlockedItem> get blocked => _blocked;

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
      // Only the mixes of a taste need them: without them the rest of the library is still shown
      final listens = await _backend.listens().catchError((_) => _listens);
      final playlists = await _backend.playlists();
      final forYou = await _backend.forYou();
      final seedLists = await _backend.seedLists();
      // Suggestions are extras: if they cannot be read, the library is still shown
      final discover = await _backend.discover().catchError((_) => _discover);
      final blocked = await _backend.blocked().catchError((_) => _blocked);
      final downloads = await _backend.downloads();
      // The music on the phone is extra, and its list is only read while someone looks at it
      final localStatus = await _backend.localStatus().catchError(
        (_) => _localStatus,
      );
      final local = _localOpen
          ? await _backend.localTracks().catchError((_) => localSongs.value)
          : localSongs.value;
      final items = <int, List<Track>>{};
      for (final id in _items.keys.toList()) {
        if (playlists.any((p) => p.id == id)) {
          items[id] = await _backend.playlistTracks(id);
        }
      }
      _setLiked(liked);
      _recent = _oncePerSong(recent);
      _listens = listens;
      _playlists = playlists;
      _forYou = forYou;
      _seedLists = seedLists;
      _discover = discover;
      _blocked = blocked;
      _downloads = downloads;
      _downloadStates = {for (final d in downloads) d.track.videoId: d.state};
      _localStatus = localStatus;
      if (!listEquals(local, localSongs.value)) localSongs.value = local;
      _items
        ..clear()
        ..addAll(items);
      notifyListeners();
      unawaited(_refreshContext());
    } on Object {
      // Nothing to show is better than an error on every screen
    }
  }

  /// The list of the music on this phone is on show (or not any more): while it is, it is kept up to date.
  Future<void> watchLocal(bool on) async {
    _localOpen = on;
    if (on) await _loadLocal();
  }

  /// Reads the status and the files of the music on this phone and nothing else. What changed is told: the list to the
  /// page that shows it, and the status (the count, the switch) to those that show that.
  Future<void> _loadLocal() async {
    try {
      final status = await _backend.localStatus();
      final list = _localOpen ? await _backend.localTracks() : localSongs.value;
      final statusChanged = status != _localStatus;
      _localStatus = status;
      if (!listEquals(list, localSongs.value)) localSongs.value = list;
      if (statusChanged) notifyListeners();
    } on Object {
      // What is shown stays as it was
    }
  }

  /// Reads the music on this phone again, if the person allowed it and has the list on. Does nothing otherwise.
  Future<void> scanLocal() async {
    if (!_localStatus.enabled || _localStatus.access != LocalAccess.granted) {
      return;
    }
    try {
      _lastScan = await _backend.localScan();
    } on Object catch (e) {
      _messages.add('$e');
    }
    // The native side tells the library when a scan changed something, which reads everything again; a scan that found
    // the same files says nothing, and costs the screens nothing
    await _loadLocal();
  }

  /// Asks to read the music on this phone, and reads it when that was allowed.
  Future<void> requestLocalAccess() async {
    try {
      await _backend.localAccess();
    } on Object catch (e) {
      _messages.add('$e');
    }
    await _loadLocal();
    await scanLocal();
  }

  /// Copies music files the person chooses into the folder of the app (an iPhone); gives back how many, or null.
  Future<int?> importLocal() async {
    try {
      final copied = await _backend.localImport();
      if (copied != null && copied > 0) await scanLocal();
      return copied;
    } on Object catch (e) {
      _messages.add('$e');
      return null;
    }
  }

  Future<void> setLocalEnabled(bool on) async {
    await _run(() => _backend.setLocalEnabled(on));
    await _loadLocal();
  }

  /// Reads the mix for this time of day, which may have to fetch a list: it must not hold the other lists back.
  Future<void> _refreshContext() async {
    try {
      _context = await _backend.contextMix();
      notifyListeners();
    } on Object {
      // The shelf stays as it was
    }
  }

  /// Asks not to be offered [track], or with [artistOnly] its artist, any more.
  Future<void> block(Track track, {bool artistOnly = false}) async {
    await _run(() => _backend.block(track, artistOnly: artistOnly));
    await refresh();
  }

  /// Lets a blocked song or artist be offered again.
  Future<void> unblock(BlockedItem item) async {
    await _run(() => _backend.unblock(item));
    await refresh();
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
      _seedLists = await _backend.seedLists();
      _discover = await _backend.discover().catchError((_) => _discover);
      notifyListeners();
      unawaited(_refreshContext());
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
    localSongs.dispose();
    super.dispose();
  }
}
