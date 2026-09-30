import 'dart:async';

import 'package:flutter/foundation.dart';

import '../strings.dart';
import 'backend.dart';
import 'models.dart';
import 'recent_rooms.dart';

/// Something another member did that moved this device: worth a snackbar, sometimes with a way out.
class Notice {
  const Notice(this.text, {this.canKeepPlaying = false});

  final String text;

  /// The room paused and this device may prefer to go on alone.
  final bool canKeepPlaying;
}

/// The room as the UI sees it: latest state from the native side plus the actions a user can take.
///
/// Room structure notifies listeners rarely; the player position lives in [player] and is
/// extrapolated by [positionMs], so nothing has to rebuild sixty times a second.
class RoomController extends ChangeNotifier {
  RoomController(this._backend, {this._recents});

  final Backend _backend;
  final RecentRooms? _recents;
  StreamSubscription<BackendEvent>? _subscription;

  RoomSnapshot _snapshot = const RoomSnapshot();
  Profile _profile = const Profile();
  bool _ready = false;

  /// Local player state, updated about once a second while the screen is on.
  final ValueNotifier<PlayerPosition> player = ValueNotifier(
    const PlayerPosition(),
  );
  final Stopwatch _sinceSample = Stopwatch();

  /// While the user's seek is in flight the bar stays where they dropped it.
  int? _seekTarget;
  Timer? _seekTimer;

  /// A room code from an invitation link that the UI has not dealt with yet.
  final ValueNotifier<String?> invite = ValueNotifier(null);

  final _messages = StreamController<String>.broadcast();
  final _notices = StreamController<Notice>.broadcast();

  /// What other members did to this device, see [Notice].
  Stream<Notice> get notices => _notices.stream;

  /// While listening alone, what the play button shows right after a tap, before the player reports back.
  bool? _soloPlaying;

  /// Short notices for a snackbar: server errors, failed actions.
  Stream<String> get messages => _messages.stream;

  RoomSnapshot get snapshot => _snapshot;
  Profile get profile => _profile;

  /// False until the first state arrived from the native side.
  bool get ready => _ready;

  Future<void> start() async {
    _subscription = _backend.events.listen(_onEvent);
    try {
      _profile = await _backend.profile();
    } on Object {
      // The name field just starts empty
    }
    notifyListeners();
  }

  void _onEvent(BackendEvent event) {
    switch (event) {
      case StateEvent(:final snapshot):
        if (snapshot.ownPlayback != _snapshot.ownPlayback) _soloPlaying = null;
        final code = snapshot.room;
        if (code != null) _recents?.touch(code, name: snapshot.name);
        _snapshot = snapshot;
        _ready = true;
        notifyListeners();
      case NoticeEvent(:final kind, :final by, :final title):
        final who = by.isEmpty ? S.someone : by;
        if (kind == 'paused') {
          _notices.add(Notice(S.pausedBy(who), canKeepPlaying: true));
        } else if (kind == 'skipped') {
          _notices.add(Notice(S.skippedBy(who, title ?? '')));
        }
      case PositionEvent(:final position):
        _soloPlaying = null;
        _sinceSample
          ..reset()
          ..start();
        player.value = position;
      case InviteEvent(:final code):
        invite.value = code;
      case LibraryEvent():
        break; // LibraryController listens for this itself
      case ErrorEvent(:final error):
        final text = _describe(error);
        if (text != null) _messages.add(text);
    }
  }

  String? _describe(ServerError error) {
    if (error.code == 'unplayable') {
      // The server message reads "Nobody could load: <title>"
      final title = error.message.split(': ').skip(1).join(': ');
      return S.unplayable(title.isEmpty ? 'this song' : title);
    }
    return error.message;
  }

  // ------------------------------------------------------------------ derived state

  /// Position of the current song now, in ms.
  int positionMs() {
    final target = _seekTarget;
    if (target != null) return target;
    final p = player.value;
    if (!p.playing) return p.positionMs;
    final advanced =
        p.positionMs + (_sinceSample.elapsedMilliseconds * p.speed).round();
    final limit = p.durationMs > 0 ? p.durationMs : advanced;
    return advanced < limit ? advanced : limit;
  }

  /// Total length of the current song: from the player once known, else from the queue entry.
  int durationMs() {
    final fromPlayer = player.value.durationMs;
    return fromPlayer > 0 ? fromPlayer : (_snapshot.current?.durMs ?? 0);
  }

  /// Sound is coming or is already playing (used for the play/pause glyph). Outside a room, and while
  /// listening alone, this is about this device's own player, not the room.
  bool get isPlaying => _snapshot.ownPlayback
      ? (_soloPlaying ?? (player.value.playing || player.value.buffering))
      : _snapshot.wantsPlaying;

  /// The room started something but nothing is audible yet: everyone is still loading.
  bool get isStarting => _snapshot.ownPlayback
      ? isPlaying && player.value.buffering
      : _snapshot.phase == 'preparing' || (isPlaying && player.value.buffering);

  // ------------------------------------------------------------------ room

  /// Returns null on success, else a message for the user.
  Future<String?> createRoom(String name) async {
    try {
      await _backend.createRoom(name.trim());
      return null;
    } on Object catch (e) {
      return '${S.createFailed}: $e';
    }
  }

  Future<String?> join(String code, String name) async {
    try {
      await _backend.join(code.trim().toUpperCase(), name.trim());
      return null;
    } on Object catch (e) {
      return '${S.joinFailed}: $e';
    }
  }

  Future<void> leave() => _run(_backend.leave);

  /// Address that opens the app on this room from a chat message, or the app's own link when the
  /// server's address is not known.
  String inviteLink(String code) => _profile.server.isEmpty
      ? 'unison://join/$code'
      : '${_profile.server}/join/$code';

  /// What the server says about a room, for the list of recent ones.
  Future<RoomInfo?> roomInfo(String code) => _backend.roomInfo(code);

  Future<void> setRoomName(String name) =>
      _run(() => _backend.setRoomName(name.trim()));

  Future<void> setGuestControl(GuestControl mode) =>
      _run(() => _backend.setGuestControl(mode));

  /// Owner only: remove a member from the room.
  Future<void> kick(Member member) => _run(() => _backend.kick(member.id));

  /// Changes the name the others see; playback carries on.
  Future<void> rename(String name) => _run(() => _backend.rename(name.trim()));

  /// Sends the room code (and a link that opens the app on it) through the share sheet.
  Future<void> shareInvite() {
    final code = _snapshot.room;
    if (code == null) return Future.value();
    return _run(() => _backend.share(S.inviteText(code, inviteLink(code))));
  }

  // ------------------------------------------------------------------ transport

  Future<void> togglePlay() {
    final playing = isPlaying;
    if (_snapshot.ownPlayback) {
      _soloPlaying = !playing;
      notifyListeners();
    }
    return _run(playing ? _backend.pause : _backend.play);
  }

  /// Listen on this device alone ([on]) or follow the room again.
  Future<void> setSolo(bool on) => _run(() => _backend.setSolo(on));

  /// Carry on playing by myself after the room paused.
  Future<void> keepPlaying() => _run(_backend.keepPlaying);
  Future<void> next() => _run(_backend.next);
  Future<void> prev() => _run(_backend.prev);
  Future<void> jump(QueueEntry entry) => _run(() => _backend.jump(entry.id));

  Future<void> seek(int positionMs) {
    _seekTarget = positionMs;
    _seekTimer?.cancel();
    _seekTimer = Timer(
      const Duration(milliseconds: 1500),
      () => _seekTarget = null,
    );
    return _run(() => _backend.seek(positionMs));
  }

  // ------------------------------------------------------------------ queue

  Future<void> add(Track track, {bool playNext = false}) =>
      _run(() => _backend.add(track, playNext: playNext));
  Future<void> remove(QueueEntry entry) =>
      _run(() => _backend.remove(entry.id));
  Future<void> move(QueueEntry entry, int toIndex) =>
      _run(() => _backend.move(entry.id, toIndex));
  Future<void> clearQueue() => _run(_backend.clear);
  Future<void> shuffle() => _run(_backend.shuffle);
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) =>
      _run(() => _backend.addMany(tracks, playNext: playNext));

  /// Outside a room: replaces the queue with [tracks] and starts them. In a room the queue belongs
  /// to everybody, so they are only added to it.
  Future<void> playTracks(List<Track> tracks) async {
    if (!_snapshot.inRoom) await _run(_backend.clear);
    await addMany(tracks);
  }

  Future<void> cycleRepeat() =>
      _run(() => _backend.setRepeat(_snapshot.repeat.next));

  // ------------------------------------------------------------------ search and settings

  Future<List<Track>> search(String query, {bool songsOnly = false}) =>
      _backend.search(query, songsOnly: songsOnly);
  Future<LinkResult?> lookup(String text) => _backend.lookup(text);
  Future<List<PlaylistRef>> searchPlaylists(String query) =>
      _backend.searchPlaylists(query);

  /// Whether the music carries on with similar songs when the queue runs out.
  bool get autoplay => _profile.autoplay;

  Future<void> setAutoplay(bool on) {
    _profile = _profile.withAutoplay(on);
    notifyListeners();
    return _run(() => _backend.setAutoplay(on));
  }

  /// What YouTube would complete a half-typed search to.
  Future<List<String>> suggest(String query) async {
    try {
      return await _backend.suggest(query);
    } on Object {
      return const [];
    }
  }

  Future<void> setTrim(int ms) => _run(() => _backend.setTrim(ms));

  /// Play songs with their picture on this device, or sound only.
  Future<void> setVideoMode(bool on) => _run(() => _backend.setVideoMode(on));

  Future<void> setVideoVisible(bool visible) =>
      _run(() => _backend.setVideoVisible(visible));

  /// The texture the picture is drawn into, or null when it cannot be made.
  Future<int?> videoSurface() async {
    try {
      return await _backend.videoSurface();
    } on Object {
      return null;
    }
  }

  Future<void> setVideoQuality(int height) =>
      _run(() => _backend.setVideoQuality(height));
  Future<List<String>> log() => _backend.log();

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on BackendException catch (e) {
      _messages.add(e.code == 'no_room' ? S.notInRoom : e.message);
    } on Object catch (e) {
      _messages.add('$e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _seekTimer?.cancel();
    _messages.close();
    _notices.close();
    player.dispose();
    invite.dispose();
    super.dispose();
  }
}
