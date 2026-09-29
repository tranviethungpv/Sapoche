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

  /// When set, searches wait for it, so a test can look at the loading state.
  Completer<void>? searchGate;

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
  Future<void> setSolo(bool on) => _record('solo $on');

  @override
  Future<void> keepPlaying() => _record('keepPlaying');

  @override
  Future<void> add(Track track, {bool playNext = false}) =>
      _record('add ${track.videoId} next=$playNext');

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) => _record(
    'addMany ${tracks.map((t) => t.videoId).join(',')} next=$playNext',
  );

  @override
  Future<void> setRepeat(Repeat mode) => _record('repeat ${mode.name}');

  @override
  Future<void> rename(String name) => _record('rename $name');

  @override
  Future<void> share(String text) => _record('share $text');

  @override
  Future<void> remove(String itemId) => _record('remove $itemId');

  @override
  Future<void> move(String itemId, int toIndex) =>
      _record('move $itemId $toIndex');

  @override
  Future<void> clear() => _record('clear');

  List<PlaylistRef> playlistResults = const [];

  @override
  Future<List<PlaylistRef>> searchPlaylists(String query) async {
    await _record('searchPlaylists $query');
    return playlistResults;
  }

  @override
  Future<void> shuffle() => _record('shuffle');

  @override
  Future<void> setVideoMode(bool on) => _record('video $on');

  @override
  Future<void> setVideoVisible(bool visible) =>
      _record('videoVisible $visible');

  @override
  Future<int> videoSurface() async {
    await _record('videoSurface');
    return 7;
  }

  @override
  Future<void> setVideoQuality(int height) => _record('videoQuality $height');

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false}) async {
    await _record(songsOnly ? 'search $query songs' : 'search $query');
    await searchGate?.future;
    return searchResults;
  }

  LinkResult? lookupResult;

  @override
  Future<LinkResult?> lookup(String text) async {
    await _record('lookup $text');
    return lookupResult;
  }

  RoomInfo? roomInfoResult;

  @override
  Future<RoomInfo?> roomInfo(String code) async {
    await _record('roomInfo $code');
    return roomInfoResult;
  }

  @override
  Future<void> kick(String memberId) => _record('kick $memberId');

  @override
  Future<void> setRoomName(String name) => _record('roomName $name');

  @override
  Future<void> setGuestControl(GuestControl mode) =>
      _record('guestControl ${mode.name}');

  @override
  Future<void> setTrim(int ms) => _record('setTrim $ms');

  @override
  Future<List<String>> log() async => ['line one', 'line two'];
}

RoomSnapshot sampleRoom({
  String phase = 'playing',
  int index = 0,
  int songs = 3,
  Repeat repeat = Repeat.off,
  List<Member>? members,
  bool video = false,
  bool solo = false,
  String? soloItemId,
  String? name,
  String? ownerId,
  GuestControl guestControl = GuestControl.all,
}) => RoomSnapshot(
  room: 'ABC234',
  link: Link.connected,
  you: 'me',
  phase: phase,
  index: index,
  repeat: repeat,
  solo: solo,
  video: video,
  soloItemId: soloItemId,
  name: name,
  ownerId: ownerId,
  guestControl: guestControl,
  members:
      members ??
      const [
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
