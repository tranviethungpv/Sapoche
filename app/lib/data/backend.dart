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

  Future<void> add(Track track, {bool playNext = false});
  Future<void> remove(String itemId);
  Future<void> move(String itemId, int toIndex);
  Future<void> clear();

  Future<List<Track>> search(String query);

  /// A track for a pasted YouTube link, or null when the text is not a link.
  Future<Track?> lookup(String text);

  Future<void> setTrim(int ms);
  Future<List<String>> log();
}

/// [Backend] over Flutter platform channels, see UnisonBridge.kt.
class NativeBackend implements Backend {
  static const _control = MethodChannel('app.unison/control');
  static const _state = EventChannel('app.unison/state');

  @override
  Stream<BackendEvent> get events => _state.receiveBroadcastStream().map((raw) {
    final json = jsonDecode(raw as String) as Map<String, dynamic>;
    return switch (json['type']) {
      'position' => PositionEvent(PlayerPosition.fromJson(json)),
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
  Future<void> add(Track track, {bool playNext = false}) => _call('add', {
    'videoId': track.videoId,
    'title': track.title,
    'artist': track.artist,
    'thumb': track.thumb,
    'durMs': track.durMs,
    'next': playNext,
  });

  @override
  Future<void> remove(String itemId) => _call('remove', {'id': itemId});

  @override
  Future<void> move(String itemId, int toIndex) =>
      _call('move', {'id': itemId, 'to': toIndex});

  @override
  Future<void> clear() => _call('clear');

  @override
  Future<List<Track>> search(String query) async {
    final raw = await _call<List<Object?>>('search', {'query': query});
    return [
      for (final e in raw ?? const [])
        Track.fromMap(e as Map<Object?, Object?>),
    ];
  }

  @override
  Future<Track?> lookup(String text) async {
    final raw = await _call<Map<Object?, Object?>>('lookup', {'text': text});
    return raw == null ? null : Track.fromMap(raw);
  }

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
