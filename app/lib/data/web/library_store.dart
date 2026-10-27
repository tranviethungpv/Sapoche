import 'dart:async';
import 'dart:convert';

import '../models.dart';
import '../music_models.dart';
import 'wire.dart';

/// Where the library is kept between visits: one document, read when the app starts and written after a change.
abstract interface class LibraryDisk {
  Future<String?> read();
  Future<void> write(String json);
}

/// What a person keeps in the app: songs they liked, what they listened to and their playlists, in memory with the
/// whole of it saved to [disk] a moment after each change. Dart counterpart of `LibraryStore.kt` and `LibraryStore.swift`
/// for the parts a browser has (no downloads and no files on the device).
///
/// [tracks] holds the details of every song something points to, so lists can be shown without the network; a song
/// nothing points to any more is dropped.
class LibraryStore {
  LibraryStore({this.disk, String? stored, int Function()? nowMs, this.saveAfter = const Duration(milliseconds: 400)})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (stored != null) {
      try {
        _load(jsonDecode(stored) as Map<String, Object?>);
      } on Object {
        // A document that cannot be read is an empty library, as a database that cannot be opened would be
      }
    }
  }

  final LibraryDisk? disk;
  final Duration saveAfter;
  final int Function() _now;

  /// Called after every change, so a screen that shows the library can refresh.
  void Function()? onChanged;

  static const recentLimit = 100;
  static const historyKeep = 2000;
  static const skipsKeep = 300;
  static const maxPlaylist = 500;
  static const maxName = 60;
  static const coverParts = 4;

  final _tracks = <String, Track>{};
  // Liked songs by id, with the time they were liked
  final _likes = <String, int>{};
  // One entry per listen, oldest first
  final _history = <(String, int)>[];
  // Songs left after a few seconds, oldest first
  final _skips = <(String, int)>[];
  // What was asked not to be offered, the latest last
  final _blocked = <_Blocked>[];
  // What YouTube listed beside a seed song, by the seed's id
  final _suggestions = <String, _Cached>{};
  final _playlists = <_Playlist>[];
  final _folders = <_Folder>[];
  var _nextId = 1;
  Timer? _saving;
  var _dirty = false;

  /// The name given to a playlist or folder that has none; the app sets it to the language of the screen.
  String Function() unnamed = () => 'Untitled';

  // ------------------------------------------------------------------ likes

  /// Liked songs, the most recently liked first.
  List<Track> liked() {
    final ids = _likes.keys.toList()
      ..sort((a, b) {
        final byTime = _likes[b]!.compareTo(_likes[a]!);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return [for (final id in ids) _tracks[id]!];
  }

  /// Liked songs with the time each was liked, the latest first: what the taste is worked out from.
  List<HistoryEntry> likedEntries() => [
    for (final t in liked())
      HistoryEntry(track: t, at: DateTime.fromMillisecondsSinceEpoch(_likes[t.videoId]!), plays: 1),
  ];

  /// Ids of the liked songs.
  Set<String> likedIds() => _likes.keys.toSet();

  void setLiked(Track track, bool liked) {
    if (liked) {
      _remember(track);
      // Liking a song that is already liked keeps the time it was first liked
      _likes.putIfAbsent(track.videoId, _now);
    } else {
      _likes.remove(track.videoId);
      _dropUnused();
    }
    _changed();
  }

  // ------------------------------------------------------------------ history

  /// Songs heard, once each, the one heard last first.
  List<HistoryEntry> recent({int limit = recentLimit}) {
    final last = <String, int>{};
    final plays = <String, int>{};
    for (final (id, at) in _history) {
      if (at >= (last[id] ?? 0)) last[id] = at;
      plays[id] = (plays[id] ?? 0) + 1;
    }
    final ids = last.keys.toList()
      ..sort((a, b) {
        final byTime = last[b]!.compareTo(last[a]!);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return [
      for (final id in ids.take(limit))
        HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(last[id]!), plays: plays[id]!),
    ];
  }

  /// [track] was heard. Only the last [historyKeep] listens are kept.
  void recordListen(Track track) {
    _remember(track);
    _history.add((track.videoId, _now()));
    if (_history.length > historyKeep) _history.removeRange(0, _history.length - historyKeep);
    _dropUnused();
    _changed();
  }

  /// Every listen, the latest first, each with its own time: what the taste is worked out from.
  List<HistoryEntry> listens({int limit = historyKeep}) => [
    for (final (id, at) in _history.reversed.take(limit))
      HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(at), plays: 1),
  ];

  /// Ids of the songs heard since [since] (ms since the epoch).
  Set<String> heardSince(int since) => {
    for (final (id, at) in _history)
      if (at >= since) id,
  };

  /// [track] was left after a few seconds. Only the last [skipsKeep] are kept. It is not announced: nothing shows it.
  void recordSkip(Track track) {
    _remember(track);
    _skips.add((track.videoId, _now()));
    if (_skips.length > skipsKeep) _skips.removeRange(0, _skips.length - skipsKeep);
    _dropUnused();
    _save();
  }

  /// Songs left after a few seconds, the latest first, each time one entry.
  List<HistoryEntry> skipped() => [
    for (final (id, at) in _skips.reversed)
      HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(at), plays: 1),
  ];

  void clearHistory() {
    _history.clear();
    // What was left is part of the listening a person asked to forget
    _skips.clear();
    _dropUnused();
    _changed();
  }

  // ------------------------------------------------------------------ blocked

  /// Blocks a `song` (key: video id) or an `artist` (key: `Taste.artistKey`); blocking again changes the label.
  void block(String kind, String key, String label) {
    _blocked.removeWhere((b) => b.kind == kind && b.key == key);
    _blocked.add(_Blocked(kind, key, label, _now()));
    _changed();
  }

  void unblock(String kind, String key) {
    _blocked.removeWhere((b) => b.kind == kind && b.key == key);
    _changed();
  }

  /// What was blocked, the latest first.
  List<BlockedItem> blocked() => [
    for (final b in _blocked.reversed) BlockedItem(kind: b.kind, key: b.key, label: b.label),
  ];

  // ------------------------------------------------------------------ suggestions

  /// What was kept for [seed], or null.
  ({List<TrackRef> tracks, int fetchedAt})? cachedSuggestions(String seed) {
    final kept = _suggestions[seed];
    return kept == null ? null : (tracks: kept.tracks, fetchedAt: kept.fetchedAt);
  }

  void putSuggestions(String seed, List<TrackRef> tracks, int at) {
    _suggestions[seed] = _Cached(tracks, at);
    _changed();
  }

  /// Forgets what was kept for every seed but [seeds].
  void keepSuggestionsFor(Iterable<String> seeds) {
    final keep = seeds.toSet();
    if (_suggestions.keys.every(keep.contains)) return;
    _suggestions.removeWhere((seed, _) => !keep.contains(seed));
    _save();
  }

  // ------------------------------------------------------------------ playlists

  /// Playlists, the one changed last first.
  List<SavedPlaylist> playlists() {
    final sorted = [..._playlists]..sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return [
      for (final p in sorted)
        SavedPlaylist(
          id: p.id,
          name: p.name,
          count: p.items.length,
          thumbs: _coverThumbs(p),
          folderId: p.folderId,
        ),
    ];
  }

  /// The pictures of the first songs, each once: what the cover of a playlist is made of.
  List<String> _coverThumbs(_Playlist p) {
    final thumbs = <String>[];
    for (final id in p.items) {
      final thumb = _tracks[id]?.thumb;
      if (thumb != null && !thumbs.contains(thumb)) thumbs.add(thumb);
      if (thumbs.length == coverParts) break;
    }
    return thumbs;
  }

  /// The songs of a playlist in order; empty when there is no such playlist.
  List<Track> playlistTracks(int id) => [
    for (final songId in _playlist(id)?.items ?? const <String>[]) _tracks[songId]!,
  ];

  /// Makes a playlist, with [tracks] in it if given, and returns its id.
  int createPlaylist(String name, List<Track> tracks) {
    final at = _now();
    final playlist = _Playlist(_nextId++, _cleanName(name), at, at);
    _playlists.add(playlist);
    _append(playlist, tracks);
    _changed();
    return playlist.id;
  }

  void renamePlaylist(int id, String name) => _change(id, (p) => p.name = _cleanName(name));

  /// Deletes the playlist; the songs stay wherever else they are kept.
  void deletePlaylist(int id) {
    _playlists.removeWhere((p) => p.id == id);
    _dropUnused();
    _changed();
  }

  /// Adds songs at the end; those already in the playlist are left where they are. Returns how many were added.
  int addToPlaylist(int id, List<Track> tracks) {
    var added = 0;
    _change(id, (p) => added = _append(p, tracks));
    return added;
  }

  void removeFromPlaylist(int id, String videoId) => _change(id, (p) {
    p.items.remove(videoId);
    _dropUnused();
  });

  /// Puts a song at place [toIndex] (0 is the top) of the playlist.
  void movePlaylistItem(int id, String videoId, int toIndex) => _change(id, (p) {
    if (!p.items.remove(videoId)) return;
    p.items.insert(toIndex.clamp(0, p.items.length), videoId);
  });

  int _append(_Playlist p, List<Track> tracks) {
    var added = 0;
    for (final track in tracks) {
      if (p.items.length >= maxPlaylist) break;
      if (p.items.contains(track.videoId)) continue;
      _remember(track);
      p.items.add(track.videoId);
      added++;
    }
    return added;
  }

  /// Runs [change] on one playlist, stamps it as changed and announces it.
  void _change(int id, void Function(_Playlist p) change) {
    final playlist = _playlist(id);
    if (playlist == null) return;
    change(playlist);
    playlist.updatedAt = _now();
    _changed();
  }

  _Playlist? _playlist(int id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ------------------------------------------------------------------ folders

  /// Folders, the one changed last first.
  List<PlaylistFolder> folders() {
    final sorted = [..._folders]..sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return [for (final f in sorted) PlaylistFolder(id: f.id, name: f.name)];
  }

  /// Makes a folder and returns its id.
  int createFolder(String name) {
    final at = _now();
    final folder = _Folder(_nextId++, _cleanName(name), at);
    _folders.add(folder);
    _changed();
    return folder.id;
  }

  void renameFolder(int id, String name) {
    final folder = _folder(id);
    if (folder == null) return;
    folder
      ..name = _cleanName(name)
      ..updatedAt = _now();
    _changed();
  }

  /// Deletes the folder; its playlists stay, out of any folder.
  void deleteFolder(int id) {
    for (final p in _playlists) {
      if (p.folderId == id) p.folderId = null;
    }
    _folders.removeWhere((f) => f.id == id);
    _changed();
  }

  /// Puts the playlist in the folder, or out of any with a null [folderId]. The playlist is not counted as changed, but
  /// the folder is.
  void setPlaylistFolder(int id, int? folderId) {
    final playlist = _playlist(id);
    if (playlist == null) return;
    final at = _now();
    for (final folder in {playlist.folderId, folderId}) {
      if (folder != null) _folder(folder)?.updatedAt = at;
    }
    playlist.folderId = folderId;
    _changed();
  }

  _Folder? _folder(int id) {
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  // ------------------------------------------------------------------ keeping

  String _cleanName(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return unnamed();
    return clean.length > maxName ? clean.substring(0, maxName) : clean;
  }

  void _remember(Track track) => _tracks[track.videoId] = Track(
    videoId: track.videoId,
    title: track.title,
    artist: track.artist,
    thumb: track.thumb,
    durMs: track.durMs,
  );

  void _dropUnused() {
    final used = {
      ..._likes.keys,
      for (final (id, _) in _history) id,
      for (final (id, _) in _skips) id,
      for (final p in _playlists) ...p.items,
    };
    _tracks.removeWhere((id, _) => !used.contains(id));
  }

  void _changed() {
    onChanged?.call();
    _save();
  }

  /// Writes the library after the pause, without telling the screens: nothing they show changed.
  void _save() {
    if (disk == null) return;
    _dirty = true;
    _saving?.cancel();
    _saving = Timer(saveAfter, flush);
  }

  /// Writes what changed now rather than after the pause, for a page that is going away.
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    _saving?.cancel();
    await disk?.write(jsonEncode(_toJson()));
  }

  Map<String, Object?> _toJson() => {
    'v': 2,
    'next': _nextId,
    'tracks': [
      for (final t in _tracks.values) [t.videoId, t.title, t.artist, t.thumb, t.durMs],
    ],
    'likes': [for (final e in _likes.entries) [e.key, e.value]],
    'history': [for (final (id, at) in _history) [id, at]],
    'skips': [for (final (id, at) in _skips) [id, at]],
    'blocked': [
      for (final b in _blocked) [b.kind, b.key, b.label, b.at],
    ],
    'suggestions': {
      for (final e in _suggestions.entries)
        e.key: {
          'at': e.value.fetchedAt,
          'tracks': [for (final t in e.value.tracks) [t.videoId, t.title, t.artist, t.thumb, t.durMs]],
        },
    },
    'playlists': [
      for (final p in _playlists)
        {'id': p.id, 'name': p.name, 'created': p.createdAt, 'updated': p.updatedAt, 'folder': p.folderId, 'items': p.items},
    ],
    'folders': [
      for (final f in _folders) {'id': f.id, 'name': f.name, 'updated': f.updatedAt},
    ],
  };

  void _load(Map<String, Object?> json) {
    for (final row in json['tracks'] as List) {
      final t = row as List;
      _tracks[t[0] as String] = Track(
        videoId: t[0] as String,
        title: t[1] as String,
        artist: t[2] as String,
        thumb: t[3] as String?,
        durMs: (t[4] as num).toInt(),
      );
    }
    for (final row in json['likes'] as List) {
      final l = row as List;
      _likes[l[0] as String] = (l[1] as num).toInt();
    }
    for (final row in json['history'] as List) {
      final h = row as List;
      _history.add((h[0] as String, (h[1] as num).toInt()));
    }
    // A document written before the taste had none of these
    for (final row in json['skips'] as List? ?? const []) {
      final h = row as List;
      _skips.add((h[0] as String, (h[1] as num).toInt()));
    }
    for (final row in json['blocked'] as List? ?? const []) {
      final b = row as List;
      _blocked.add(_Blocked(b[0] as String, b[1] as String, b[2] as String, (b[3] as num).toInt()));
    }
    (json['suggestions'] as Map<String, Object?>? ?? const {}).forEach((seed, value) {
      final m = value as Map<String, Object?>;
      _suggestions[seed] = _Cached([
        for (final row in m['tracks'] as List)
          TrackRef(
            (row as List)[0] as String,
            row[1] as String,
            row[2] as String,
            row[3] as String?,
            (row[4] as num).toInt(),
          ),
      ], (m['at'] as num).toInt());
    });
    for (final p in json['playlists'] as List) {
      final m = p as Map<String, Object?>;
      _playlists.add(
        _Playlist(
          (m['id'] as num).toInt(),
          m['name'] as String,
          (m['created'] as num).toInt(),
          (m['updated'] as num).toInt(),
        )
          ..folderId = (m['folder'] as num?)?.toInt()
          ..items.addAll((m['items'] as List).cast<String>()),
      );
    }
    for (final f in json['folders'] as List) {
      final m = f as Map<String, Object?>;
      _folders.add(_Folder((m['id'] as num).toInt(), m['name'] as String, (m['updated'] as num).toInt()));
    }
    _nextId = (json['next'] as num).toInt();
  }
}

class _Playlist {
  _Playlist(this.id, this.name, this.createdAt, this.updatedAt);

  final int id;
  String name;
  final int createdAt;
  int updatedAt;
  int? folderId;
  final items = <String>[];
}

class _Folder {
  _Folder(this.id, this.name, this.updatedAt);

  final int id;
  String name;
  int updatedAt;
}

class _Blocked {
  _Blocked(this.kind, this.key, this.label, this.at);

  final String kind;
  final String key;
  final String label;
  final int at;
}

class _Cached {
  _Cached(this.tracks, this.fetchedAt);

  final List<TrackRef> tracks;
  final int fetchedAt;
}
