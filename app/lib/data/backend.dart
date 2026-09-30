import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';

sealed class BackendEvent {
  const BackendEvent();
}

class StateEvent extends BackendEvent {
  const StateEvent(this.snapshot);
  final RoomSnapshot snapshot;
}

class PositionEvent extends BackendEvent {
  const PositionEvent(this.position);
  final PlayerPosition position;
}

/// Someone opened a `unison://join/CODE` link.
class InviteEvent extends BackendEvent {
  const InviteEvent(this.code);
  final String code;
}

/// Another member paused the room ([kind] `paused`) or switched the song (`skipped`).
class NoticeEvent extends BackendEvent {
  const NoticeEvent({required this.kind, required this.by, this.title});
  final String kind;
  final String by;
  final String? title;
}

/// Liked songs or the history changed, possibly while the screen was off.
class LibraryEvent extends BackendEvent {
  const LibraryEvent();
}

class ErrorEvent extends BackendEvent {
  const ErrorEvent(this.error);
  final ServerError error;
}

/// Everything the UI needs from the native side: commands and a stream of state.
/// The player and the room connection live in the Android foreground service, not here.
abstract class Backend {
  Stream<BackendEvent> get events;

  Future<Profile> profile();
  Future<String> createRoom(String name);
  Future<void> join(String code, String name);
  Future<void> leave();

  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> prev();
  Future<void> seek(int positionMs);
  Future<void> jump(String itemId);

  /// Listen on this device alone ([on]) or follow the room again.
  Future<void> setSolo(bool on);

  /// The room stopped but this device carries on by itself.
  Future<void> keepPlaying();

  Future<void> add(Track track, {bool playNext = false});
  Future<void> addMany(List<Track> tracks, {bool playNext = false});
  Future<void> setRepeat(Repeat mode);
  Future<void> remove(String itemId);
  Future<void> move(String itemId, int toIndex);
  Future<void> clear();

  /// Videos matching [query]; with [songsOnly] just what YouTube Music lists as songs.
  Future<List<Track>> search(String query, {bool songsOnly = false});

  /// Playlists matching [query].
  Future<List<PlaylistRef>> searchPlaylists(String query);

  /// Mixes up the songs still to come; with the queue finished, mixes them all and plays from the top.
  Future<void> shuffle();

  /// Play songs with their picture ([on]) or sound only.
  Future<void> setVideoMode(bool on);

  /// The picture is on screen ([visible]) or not; off, it is neither downloaded nor decoded.
  Future<void> setVideoVisible(bool visible);

  /// The id of the texture the picture is drawn into.
  Future<int> videoSurface();

  /// Tallest picture to fetch, in pixels.
  Future<void> setVideoQuality(int height);

  /// The songs behind a pasted YouTube link, or null when the text is not a link.
  Future<LinkResult?> lookup(String text);

  /// What the server says about the room with [code], or null when it cannot be reached.
  Future<RoomInfo?> roomInfo(String code);

  /// Owner only: remove a member from the room.
  Future<void> kick(String memberId);

  Future<void> setRoomName(String name);

  /// Owner only.
  Future<void> setGuestControl(GuestControl mode);

  Future<void> rename(String name);

  /// Opens the system share sheet with [text].
  Future<void> share(String text);

  /// Liked songs, the most recently liked first.
  Future<List<Track>> liked();

  /// Songs heard, once each, the most recent first.
  Future<List<HistoryEntry>> recent();

  Future<void> setLiked(Track track, bool liked);
  Future<void> clearHistory();

  /// The songs on the list of downloads, what is on the phone first.
  Future<List<DownloadEntry>> downloads();

  /// Asks for [tracks] to be downloaded. Gives back false, having done nothing, when the phone is on mobile
  /// data and [allowMetered] is not set: the person has to be asked first.
  Future<bool> download(List<Track> tracks, {bool allowMetered = false});

  Future<void> removeDownload(String videoId);
  Future<void> clearDownloads();

  Future<StorageInfo> storage();
  Future<void> clearPlayCache();

  /// Size of the cache of played songs in MB; counts from the next start of the app.
  Future<void> setCacheLimit(int mb);
  Future<void> setAutoDownload(bool on);

  /// Songs to offer, from what was kept; works without a network.
  Future<List<Track>> forYou();

  /// Fetches the suggestions again, whatever their age, and gives back the new list.
  Future<List<Track>> refreshSuggestions();

  /// What YouTube would complete [query] to; empty when it cannot say.
  Future<List<String>> suggest(String query);

  /// Whether the music carries on with similar songs when the queue runs out.
  Future<void> setAutoplay(bool on);

  /// The person's playlists, the one changed last first.
  Future<List<SavedPlaylist>> playlists();
  Future<List<Track>> playlistTracks(int id);

  /// Makes a playlist and gives back its id.
  Future<int> createPlaylist(String name, List<Track> tracks);
  Future<void> renamePlaylist(int id, String name);
  Future<void> deletePlaylist(int id);

  /// Adds songs to the end; those already there stay put. Gives back how many were added.
  Future<int> addToPlaylist(int id, List<Track> tracks);
  Future<void> removeFromPlaylist(int id, String videoId);
  Future<void> movePlaylistItem(int id, String videoId, int toIndex);

  Future<void> setTrim(int ms);
  Future<List<String>> log();
}

/// [Backend] over Flutter platform channels, see UnisonBridge.kt.
class NativeBackend implements Backend {
  static const _control = MethodChannel('app.unison/control');
  static const _state = EventChannel('app.unison/state');

  /// One subscription to the platform channel, shared by everyone who listens: a second call to
  /// receiveBroadcastStream would take the stream over from the first listener.
  @override
  late final Stream<BackendEvent> events = _state.receiveBroadcastStream().map((
    raw,
  ) {
    final json = jsonDecode(raw as String) as Map<String, dynamic>;
    return switch (json['type']) {
      'position' => PositionEvent(PlayerPosition.fromJson(json)),
      'library' => const LibraryEvent(),
      'invite' => InviteEvent(json['code'] as String),
      'notice' => NoticeEvent(
        kind: json['kind'] as String,
        by: json['by'] as String? ?? '',
        title: json['title'] as String?,
      ),
      'error' => ErrorEvent(
        ServerError(json['code'] as String, json['message'] as String),
      ),
      _ => StateEvent(RoomSnapshot.fromJson(json)),
    };
  });

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _control.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw BackendException(e.code, e.message ?? e.code);
    }
  }

  @override
  Future<Profile> profile() async =>
      Profile.fromMap((await _call<Map<Object?, Object?>>('profile'))!);

  @override
  Future<String> createRoom(String name) async =>
      (await _call<String>('createRoom', {'name': name}))!;

  @override
  Future<void> join(String code, String name) =>
      _call('join', {'code': code, 'name': name});

  @override
  Future<void> leave() => _call('leave');

  @override
  Future<void> play() => _call('play');

  @override
  Future<void> pause() => _call('pause');

  @override
  Future<void> next() => _call('next');

  @override
  Future<void> prev() => _call('prev');

  @override
  Future<void> seek(int positionMs) => _call('seek', {'ms': positionMs});

  @override
  Future<void> jump(String itemId) => _call('jump', {'id': itemId});

  @override
  Future<void> setSolo(bool on) => _call('solo', {'on': on});

  @override
  Future<void> keepPlaying() => _call('keepPlaying');

  @override
  Future<void> add(Track track, {bool playNext = false}) =>
      _call('add', {...track.toMap(), 'next': playNext});

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) =>
      _call('addMany', {
        'tracks': [for (final t in tracks) t.toMap()],
        'next': playNext,
      });

  @override
  Future<void> setRepeat(Repeat mode) => _call('repeat', {'mode': mode.name});

  @override
  Future<void> remove(String itemId) => _call('remove', {'id': itemId});

  @override
  Future<void> move(String itemId, int toIndex) =>
      _call('move', {'id': itemId, 'to': toIndex});

  @override
  Future<void> clear() => _call('clear');

  @override
  Future<List<PlaylistRef>> searchPlaylists(String query) async {
    final raw = await _call<List<Object?>>('searchPlaylists', {'query': query});
    return [
      for (final e in raw ?? const [])
        PlaylistRef.fromMap(e as Map<Object?, Object?>),
    ];
  }

  @override
  Future<void> shuffle() => _call('shuffle');

  @override
  Future<void> setVideoMode(bool on) => _call('videoMode', {'on': on});

  @override
  Future<void> setVideoVisible(bool visible) =>
      _call('videoVisible', {'visible': visible});

  @override
  Future<int> videoSurface() async => (await _call<int>('videoSurface'))!;

  @override
  Future<void> setVideoQuality(int height) =>
      _call('videoQuality', {'height': height});

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false}) async {
    final raw = await _call<List<Object?>>('search', {
      'query': query,
      'songsOnly': songsOnly,
    });
    return [
      for (final e in raw ?? const [])
        Track.fromMap(e as Map<Object?, Object?>),
    ];
  }

  @override
  Future<LinkResult?> lookup(String text) async {
    final raw = await _call<Map<Object?, Object?>>('lookup', {'text': text});
    return raw == null ? null : LinkResult.fromMap(raw);
  }

  @override
  Future<RoomInfo?> roomInfo(String code) async {
    try {
      final raw = await _call<Map<Object?, Object?>>('roomInfo', {
        'code': code,
      });
      return raw == null ? null : RoomInfo.fromMap(raw);
    } on BackendException {
      return null;
    }
  }

  @override
  Future<void> kick(String memberId) => _call('kick', {'id': memberId});

  @override
  Future<void> setRoomName(String name) => _call('roomName', {'name': name});

  @override
  Future<void> setGuestControl(GuestControl mode) =>
      _call('roomSettings', {'guestControl': mode.name});

  @override
  Future<void> rename(String name) => _call('rename', {'name': name});

  @override
  Future<void> share(String text) => _call('share', {'text': text});

  @override
  Future<List<Track>> liked() async => [
    for (final e in await _call<List<Object?>>('libraryLiked') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<HistoryEntry>> recent() async => [
    for (final e in await _call<List<Object?>>('libraryRecent') ?? const [])
      HistoryEntry.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<void> setLiked(Track track, bool liked) =>
      _call('libraryLike', {...track.toMap(), 'on': liked});

  @override
  Future<void> clearHistory() => _call('libraryClearHistory');

  @override
  Future<List<DownloadEntry>> downloads() async => [
    for (final e in await _call<List<Object?>>('downloads') ?? const [])
      DownloadEntry.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<bool> download(
    List<Track> tracks, {
    bool allowMetered = false,
  }) async =>
      await _call<String>('download', {
        'tracks': [for (final t in tracks) t.toMap()],
        'allowMetered': allowMetered,
      }) ==
      'queued';

  @override
  Future<void> removeDownload(String videoId) =>
      _call('downloadRemove', {'videoId': videoId});

  @override
  Future<void> clearDownloads() => _call('downloadClear');

  @override
  Future<StorageInfo> storage() async =>
      StorageInfo.fromMap((await _call<Map<Object?, Object?>>('storage'))!);

  @override
  Future<void> clearPlayCache() => _call('clearPlayCache');

  @override
  Future<void> setCacheLimit(int mb) => _call('setCacheLimit', {'mb': mb});

  @override
  Future<void> setAutoDownload(bool on) => _call('setAutoDownload', {'on': on});

  @override
  Future<List<Track>> forYou() async => [
    for (final e in await _call<List<Object?>>('forYou') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<Track>> refreshSuggestions() async => [
    for (final e
        in await _call<List<Object?>>('refreshSuggestions') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<String>> suggest(String query) async =>
      (await _call<List<Object?>>('suggest', {'query': query}) ?? const [])
          .cast<String>();

  @override
  Future<void> setAutoplay(bool on) => _call('setAutoplay', {'on': on});

  @override
  Future<List<SavedPlaylist>> playlists() async => [
    for (final e in await _call<List<Object?>>('playlists') ?? const [])
      SavedPlaylist.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<Track>> playlistTracks(int id) async => [
    for (final e
        in await _call<List<Object?>>('playlistTracks', {'id': id}) ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async =>
      (await _call<int>('playlistCreate', {
        'name': name,
        'tracks': [for (final t in tracks) t.toMap()],
      }))!;

  @override
  Future<void> renamePlaylist(int id, String name) =>
      _call('playlistRename', {'id': id, 'name': name});

  @override
  Future<void> deletePlaylist(int id) => _call('playlistDelete', {'id': id});

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async =>
      (await _call<int>('playlistAdd', {
        'id': id,
        'tracks': [for (final t in tracks) t.toMap()],
      }))!;

  @override
  Future<void> removeFromPlaylist(int id, String videoId) =>
      _call('playlistRemove', {'id': id, 'videoId': videoId});

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) =>
      _call('playlistMove', {'id': id, 'videoId': videoId, 'to': toIndex});

  @override
  Future<void> setTrim(int ms) => _call('setTrim', {'ms': ms});

  @override
  Future<List<String>> log() async =>
      (await _call<List<Object?>>('log') ?? const []).cast<String>();
}

class BackendException implements Exception {
  BackendException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}
