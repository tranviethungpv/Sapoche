import 'dart:async';

import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';

/// In-memory [Backend] that records calls and lets a test push state.
class FakeBackend implements Backend {
  final _events = StreamController<BackendEvent>.broadcast();
  final calls = <String>[];

  void emit(BackendEvent event) => _events.add(event);

  Profile profileValue = const Profile(name: 'Anna');
  List<Track> searchResults = const [];
  Object? failWith;

  @override
  Stream<BackendEvent> get events => _events.stream;

  Future<void> _record(String call) async {
    calls.add(call);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<Profile> profile() async => profileValue;

  @override
  Future<String> createRoom(String name) async {
    await _record('createRoom $name');
    return 'ABC234';
  }

  @override
  Future<void> join(String code, String name) => _record('join $code $name');

  @override
  Future<void> leave() => _record('leave');

  @override
  Future<void> play() => _record('play');

  @override
  Future<void> pause() => _record('pause');

  @override
  Future<void> next() => _record('next');

  @override
  Future<void> prev() => _record('prev');

  @override
  Future<void> seek(int positionMs) => _record('seek $positionMs');

  @override
  Future<void> jump(String itemId) => _record('jump $itemId');

  @override
  Future<void> add(Track track, {bool playNext = false}) =>
      _record('add ${track.videoId} next=$playNext');

  @override
  Future<void> remove(String itemId) => _record('remove $itemId');

  @override
  Future<void> move(String itemId, int toIndex) =>
      _record('move $itemId $toIndex');

  @override
  Future<void> clear() => _record('clear');

  @override
  Future<List<Track>> search(String query) async {
    await _record('search $query');
    return searchResults;
  }

  @override
  Future<Track?> lookup(String text) async => null;

  @override
  Future<void> setTrim(int ms) => _record('setTrim $ms');

  @override
  Future<List<String>> log() async => ['line one', 'line two'];
}

RoomSnapshot sampleRoom({
  String phase = 'playing',
  int index = 0,
  int songs = 3,
}) => RoomSnapshot(
  room: 'ABC234',
  link: Link.connected,
  you: 'me',
  phase: phase,
  index: index,
  members: const [
    Member(id: 'me', name: 'Anna', ready: true),
    Member(id: 'b', name: 'Binh', ready: true),
  ],
  queue: [
    for (var i = 0; i < songs; i++)
      QueueEntry(
        id: 'q$i',
        videoId: 'video$i',
        title: 'Song $i',
        artist: 'Artist $i',
        durMs: 200000 + i * 1000,
        addedBy: i.isEven ? 'me' : 'b',
      ),
  ],
);
