import 'dart:async';

import 'package:flutter/foundation.dart';

import '../strings.dart';
import 'backend.dart';
import 'models.dart';

/// The room as the UI sees it: latest state from the native side plus the actions a user can take.
///
/// Room structure notifies listeners rarely; the player position lives in [player] and is
/// extrapolated by [positionMs], so nothing has to rebuild sixty times a second.
class RoomController extends ChangeNotifier {
  RoomController(this._backend);

  final Backend _backend;
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

  final _messages = StreamController<String>.broadcast();

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
        _snapshot = snapshot;
        _ready = true;
        notifyListeners();
      case PositionEvent(:final position):
        _sinceSample
          ..reset()
          ..start();
        player.value = position;
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

  /// Sound is coming or is already playing (used for the play/pause glyph).
  bool get isPlaying => _snapshot.wantsPlaying;

  /// The room started something but nothing is audible yet: everyone is still loading.
  bool get isStarting =>
      _snapshot.phase == 'preparing' || (isPlaying && player.value.buffering);

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

  // ------------------------------------------------------------------ transport

  Future<void> togglePlay() => _run(isPlaying ? _backend.pause : _backend.play);
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

  // ------------------------------------------------------------------ search and settings

  Future<List<Track>> search(String query) => _backend.search(query);
  Future<Track?> lookup(String text) => _backend.lookup(text);

  Future<void> setTrim(int ms) => _run(() => _backend.setTrim(ms));
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
    player.dispose();
    super.dispose();
  }
}
