import 'dart:async';

import '../models.dart';
import 'clocks.dart';
import 'job.dart';
import 'player_port.dart';
import 'wire.dart';

/// Something that happened to this device, worth telling the person about: mostly what another member did.
sealed class RoomEvent {
  const RoomEvent();
}

class PausedEvent extends RoomEvent {
  const PausedEvent(this.byId);
  final String byId;
}

class SkippedEvent extends RoomEvent {
  const SkippedEvent(this.byId, this.title);
  final String byId;
  final String title;
}

/// This device could not load [title], while the room may well be playing it; [reason] when it is known.
class LoadFailedEvent extends RoomEvent {
  const LoadFailedEvent(this.title, this.reason);
  final String title;
  final LoadReason? reason;
}

class GroupSnapshot {
  const GroupSnapshot({
    this.state,
    this.members = const [],
    this.you,
    this.driftMs,
    this.speed = 1,
    this.solo = false,
    this.soloItemId,
    this.loading = false,
  });

  final RoomState? state;
  final List<Member> members;
  final String? you;

  /// Player position minus expected position, in ms; null when not playing in sync.
  final int? driftMs;
  final double speed;

  /// Listening on this device alone: the room's transport no longer moves it.
  final bool solo;

  /// Queue item this device is on while [solo]; the room's own current item is in [state].
  final String? soloItemId;

  /// While [solo], a song is on its way to play on this device.
  final bool loading;

  GroupSnapshot copyWith({
    RoomState? state,
    List<Member>? members,
    String? you,
    Object? driftMs = _keep,
    double? speed,
    bool? solo,
    Object? soloItemId = _keep,
    bool? loading,
  }) => GroupSnapshot(
    state: state ?? this.state,
    members: members ?? this.members,
    you: you ?? this.you,
    driftMs: identical(driftMs, _keep) ? this.driftMs : driftMs as int?,
    speed: speed ?? this.speed,
    solo: solo ?? this.solo,
    soloItemId: identical(soloItemId, _keep) ? this.soloItemId : soloItemId as String?,
    loading: loading ?? this.loading,
  );

  static const _keep = Object();
}

/// Follows the room: turns server messages into player actions so that every device plays the same position at the
/// same moment. Mirrors GroupSession.kt. Everything runs on the one event loop; message handlers only change state
/// and start jobs, and a job interleaves with them only where it waits.
class GroupSession {
  GroupSession({
    required this.player,
    required this.clock,
    required this.nowMs,
    required this.send,
    this.log = _ignore,
    DriftController? drift,
  }) : drift = drift ?? DriftController() {
    player.onEnded = () {
      if (_solo) {
        _soloStep(1, auto: true);
      } else if (_startedAtServer != null) {
        log('item ended, reporting to room (epoch $_handledEpoch)');
        send(Wire.ended(_handledEpoch));
      }
    };
    player.onError = _onPlayerError;
    player.onAdvanced = () => Job.launch((_) => _onLocalAdvance());
  }

  static void _ignore(String _) {}

  final PlayerPort player;
  final ClockSync clock;

  /// Monotonic local clock in ms, the same one the clock sync samples come from.
  final NowMs nowMs;
  final void Function(String message) send;
  final void Function(String line) log;
  final DriftController drift;

  final _events = StreamController<RoomEvent>.broadcast();
  Stream<RoomEvent> get events => _events.stream;

  GroupSnapshot _snapshot = const GroupSnapshot();
  GroupSnapshot get snapshot => _snapshot;
  void Function(GroupSnapshot snapshot) onSnapshot = (_) {};

  void _update(GroupSnapshot Function(GroupSnapshot s) change) {
    _snapshot = change(_snapshot);
    onSnapshot(_snapshot);
  }

  RoomState? _state;
  int _handledEpoch = -1;

  /// Server time of position 0 of the current item while playing in sync, else null.
  int? _startedAtServer;

  /// Queue item id currently loaded in the player, if any.
  String? _loadedItemId;

  /// Listening alone: the player keeps to this device's own choices while the room's messages only update the view.
  bool _solo = false;
  Job? _soloJob;

  /// Whether the song loading while alone plays once it is there; play and pause during the load only flip this.
  bool _soloPlayOnLoad = false;

  Job? _prepareJob;
  Job? _startJob;
  Job? _driftJob;
  final _filter = DriftFilter();

  /// Diagnostics: when false, drift is measured and logged but never corrected.
  bool correctionEnabled = true;

  /// How long the last seek took; used to aim a little ahead when correcting drift by seeking.
  int _seekCostMs = 150;

  /// Item currently handed to the player as the gapless successor of the loaded one.
  QueueEntry? _preloaded;

  /// The room advanced before this device did; adopt its start time once the local player follows.
  _PendingAdopt? _pendingAdopt;
  Job? _advanceJob;

  /// Per-device correction in ms for output latency the player does not know about. Positive means this device is
  /// heard late, so it plays that much ahead.
  int trimMs = 0;

  /// How much later than asked this device starts to be heard after play() or a seek, learned from earlier starts.
  int startBiasMs = 0;
  void Function(int bias)? onStartBiasLearned;
  bool _learnBias = false;

  /// Recoveries used since the last epoch change; stops endless retry loops on a broken stream.
  int _recoveries = 0;

  /// The item whose failed load the person was told about, so that retrying it does not tell them again and again.
  String? _reportedFailure;

  void onMessage(ServerMessage message) {
    switch (message) {
      case StateMessage():
        _onState(message);
      case MembersMessage():
        _update((s) => s.copyWith(members: message.members));
      case PrepareMessage():
        _onPrepare(message);
      case StartMessage():
        _onStart(message);
      case PauseMessage():
        _onPause(message);
      case AdvanceMessage():
        _onAdvance(message);
      case ErrorMessage():
        log('server error ${message.code}: ${message.message}');
      default:
        break; // pong, pictures, autoplay and chat are the connection's and the controller's
    }
  }

  /// Stops everything and silences the player.
  void close() {
    _held = false;
    _cancelPlayback();
    player.stop();
    _loadedItemId = null;
    _preloaded = null;
  }

  // ------------------------------------------------------------------ listening alone

  bool get isSolo => _solo;

  /// Something outside the room stopped this device: another app took the sound, a headset asked to pause. While held,
  /// what the room does loads here but does not play, see [resumeHere].
  bool _held = false;
  bool get isHeld => _held;

  void hold() => _held = true;
  void unhold() => _held = false;

  /// The person pressed play on a held device while the room plays on: go to where the room is now and play from there.
  void resumeHere() {
    Job.launch((job) async {
      _held = false;
      final started = _startedAtServer;
      final item = _state?.current;
      if (_solo || item == null || _state?.phase != 'playing') return;
      if (started == null || _loadedItemId != item.id) {
        // Not in step yet (the song came while held): load it and start where the room is
        _cancelPlayback();
        final at = _state?.startedAt;
        if (at == null) return;
        _startJob = Job.launch((j) => _catchUpPlaying(j, item, at));
        return;
      }
      final before = nowMs();
      final target = clock.toServer(before) - started + trimMs + _seekCostMs + startBiasMs;
      await job.guard(player.seekTo(target < 0 ? 0 : target));
      _seekCostMs = (nowMs() - before).clamp(50, 1000);
      player.play();
      drift.reset();
      player.setSpeed(1);
      _filter.reset(nowMs());
      _learnBias = false; // a start after being held says nothing about this device's output delay
      log('resumed here at ${target}ms after being held');
    });
  }

  /// The device plays in step with the room: the song is loaded, started, and the drift is being watched.
  bool get isInSync => _startedAtServer != null;

  /// Stops following the room and keeps playing on this device alone. Whatever is playing goes on exactly as it is.
  void goSolo() {
    if (_solo) return;
    _solo = true;
    _held = false;
    _prepareJob?.cancel();
    _startJob?.cancel();
    _driftJob?.cancel();
    _clearPendingAdopt();
    _startedAtServer = null;
    player.setSpeed(1);
    drift.reset();
    _update((s) => s.copyWith(solo: true, soloItemId: _loadedItemId, driftMs: null, speed: 1));
    send(Wire.solo(true));
    log("listening on my own from '$_loadedItemId'");
    _soloPreload();
  }

  /// Listening on one's own again after the app was closed: nothing is playing, so nothing starts until the person
  /// presses play, and then it is the song they were on.
  void restoreSolo(String? itemId) {
    if (_solo) return;
    _solo = true;
    _update((s) => s.copyWith(solo: true, soloItemId: itemId));
    log("back to listening on my own, on '$itemId'");
  }

  /// Follows the room again: asks it where it is and joins in there.
  void rejoin() {
    if (!_solo) return;
    _solo = false;
    _held = false;
    _soloJob?.cancel();
    _handledEpoch = -1; // whatever the room says next counts, even if its epoch looks familiar
    _preloaded = null;
    _update((s) => s.copyWith(solo: false, soloItemId: null, loading: false));
    send(Wire.solo(false));
    send(Wire.resync());
    log('following the room again');
  }

  /// The connection came back: the server forgot that this device listens alone.
  void onReconnected() {
    if (_solo) send(Wire.solo(true));
  }

  void soloPlay() {
    if (_soloJob?.isActive == true) {
      // The song is on its way: it plays once it is there
      _soloPlayOnLoad = true;
      _update((s) => s.copyWith(loading: true));
    } else if (_loadedItemId != null) {
      player.play();
    } else {
      // After a restart the song this device was on, else wherever the room is
      final id = _snapshot.soloItemId;
      QueueEntry? mine;
      for (final e in _state?.queue ?? const <QueueEntry>[]) {
        if (e.id == id) mine = e;
      }
      final item = mine ?? _state?.current;
      if (item != null) _soloLoad(item, 0, play: true);
    }
  }

  void soloPause() {
    // A song still on its way stays paused when it gets there
    _soloPlayOnLoad = false;
    _update((s) => s.copyWith(loading: false));
    player.pause();
  }

  void soloSeek(int positionMs) {
    if (_loadedItemId != null) player.seekTo(positionMs < 0 ? 0 : positionMs);
  }

  /// Next in the queue after the one this device is on.
  void soloNext() => _soloStep(1, auto: false);

  /// Restarts this song, or goes to the one before it when it has only just begun.
  void soloPrev() {
    if (player.positionMs() > _prevRestartsAfterMs) {
      soloSeek(0);
    } else {
      _soloStep(-1, auto: false);
    }
  }

  void soloJump(String itemId) {
    for (final e in _state?.queue ?? const <QueueEntry>[]) {
      if (e.id == itemId) _soloLoad(e, 0, play: true);
    }
  }

  /// Moves [delta] items along the room's queue from where this device is.
  void _soloStep(int delta, {required bool auto}) {
    final s = _state;
    if (s == null) return;
    final at = s.queue.indexWhere((e) => e.id == _snapshot.soloItemId);
    var target = at < 0 ? s.index : at + delta;
    if (auto && s.repeat == 'one' && at >= 0) target = at;
    if (target >= s.queue.length) target = s.repeat == 'all' ? 0 : -1;
    if (target < 0) {
      if (delta < 0 && s.queue.isNotEmpty) {
        target = 0;
      } else {
        // Ran out of songs: stop where we are
        player.pause();
        return;
      }
    }
    _soloLoad(s.queue[target], 0, play: true);
  }

  void _soloLoad(QueueEntry item, int positionMs, {required bool play}) {
    _soloJob?.cancel();
    _preloaded = null;
    _soloPlayOnLoad = play;
    _update((s) => s.copyWith(loading: play));
    _soloJob = Job.launch((job) async {
      try {
        await job.guard(player.prepare(item, positionMs));
        _loaded(item);
        _update((s) => s.copyWith(soloItemId: item.id, loading: false));
        if (_soloPlayOnLoad) player.play();
        _soloPreload();
      } on Cancelled {
        rethrow;
      } catch (e) {
        log("could not load '${item.title}' while alone: $e");
        _loadedItemId = null;
        _update((s) => s.copyWith(loading: false));
        _loadFailed(item, e);
      }
    });
  }

  /// While alone, keeps the gapless successor equal to the song after the one this device is on.
  void _soloPreload() {
    final s = _state;
    final mine = _snapshot.soloItemId;
    QueueEntry? wanted;
    if (_solo && s != null && mine != null && mine == _loadedItemId && s.repeat != 'one') {
      final at = s.queue.indexWhere((e) => e.id == mine);
      if (at >= 0 && at + 1 < s.queue.length) wanted = s.queue[at + 1];
    }
    if (wanted?.id == _preloaded?.id) return;
    _preloaded = wanted;
    player.setNext(wanted);
  }

  // ------------------------------------------------------------------ handlers

  void _onState(StateMessage msg) {
    _state = msg.state;
    _update((s) => s.copyWith(state: msg.state, members: msg.members, you: msg.you));
    if (_solo) {
      _soloPreload(); // the queue may have changed under us
      return;
    }

    // Same or older epoch: we already follow this room (e.g. the queue changed). Nothing to do.
    if (msg.state.epoch <= _handledEpoch) {
      if (_startedAtServer != null) _syncPreload(); // e.g. a track was added after the current one
      return;
    }

    switch (msg.state.phase) {
      case 'preparing':
        break; // a prepare message follows; it starts the barrier
      case 'idle':
        _handledEpoch = msg.state.epoch;
        _cancelPlayback();
        player.stop();
        _loadedItemId = null;
        _preloaded = null;
      case 'paused':
        _handledEpoch = msg.state.epoch;
        _cancelPlayback();
        final item = msg.state.current;
        if (item == null) return;
        log('catching up: paused at ${msg.state.positionMs}ms');
        _startJob = Job.launch((j) => _loadPaused(j, item, msg.state.positionMs));
      case 'playing':
        _handledEpoch = msg.state.epoch;
        _cancelPlayback();
        final item = msg.state.current;
        if (item == null) return;
        if (_loadedItemId == item.id) {
          // Reconnected while already on this item: keep playing, only realign
          log('resyncing without reloading');
          _startJob = Job.launch((j) => _resumeLoaded(j, item, msg.state.startedAt));
        } else {
          log('catching up: room is playing');
          _startJob = Job.launch((j) => _catchUpPlaying(j, item, msg.state.startedAt));
        }
    }
    if (_startedAtServer != null) _syncPreload(); // the queue may have changed
  }

  /// Applies a change the server announced without sending the whole state again.
  void _updateRoom(RoomState Function(RoomState s) change) {
    final current = _state;
    if (current == null) return;
    final changed = change(current);
    _state = changed;
    _update((s) => s.copyWith(state: changed));
  }

  void _onPrepare(PrepareMessage msg) {
    if (_solo) {
      _updateRoom(
        (s) => s.copyWith(phase: 'preparing', index: msg.index, epoch: msg.epoch, positionMs: msg.seekToMs),
      );
      return;
    }
    if (msg.epoch < _handledEpoch) return;
    final by = msg.by;
    if (by != null && by != _snapshot.you && msg.epoch != _handledEpoch) {
      _events.add(SkippedEvent(by, msg.item.title));
    }
    if (msg.epoch == _handledEpoch) {
      // The server repeats the prepare to a device that reconnected mid-barrier
      if (_prepareJob?.isActive == true) return;
      if (_loadedItemId == msg.item.id) {
        send(Wire.ready(msg.epoch));
        return;
      }
    }
    if (msg.epoch != _handledEpoch) _recoveries = 0;
    _handledEpoch = msg.epoch;
    _cancelPlayback();
    _loadedItemId = null;
    _preloaded = null;
    final epoch = msg.epoch;
    _prepareJob = Job.launch((job) async {
      try {
        final t0 = nowMs();
        await job.guard(player.prepare(msg.item, msg.seekToMs));
        _loaded(msg.item);
        log("prepared '${msg.item.title}' in ${nowMs() - t0}ms, reporting ready (epoch $epoch)");
        send(Wire.ready(epoch));
      } on Cancelled {
        rethrow;
      } catch (e) {
        log('prepare failed: $e');
        send(Wire.resolveFailed(epoch, e.toString()));
        _loadFailed(msg.item, e);
      }
    });
  }

  void _onStart(StartMessage msg) {
    if (_solo) {
      _updateRoom(
        (s) => s.copyWith(
          phase: 'playing',
          epoch: msg.epoch,
          positionMs: msg.positionMs,
          startedAt: msg.startAt - msg.positionMs,
        ),
      );
      return;
    }
    if (msg.epoch < _handledEpoch) return;
    final waitForOwnPrepare = msg.epoch == _handledEpoch && _prepareJob?.isActive == true;
    _handledEpoch = msg.epoch;
    // The server announces the start with this message only, so the UI's copy of the phase moves here
    _updateRoom(
      (s) => s.copyWith(
        phase: 'playing',
        epoch: msg.epoch,
        positionMs: msg.positionMs,
        startedAt: msg.startAt - msg.positionMs,
      ),
    );
    // Keep our own prepare running: a slow device still needs to finish loading
    _startJob?.cancel();
    _driftJob?.cancel();
    _clearPendingAdopt();
    _startedAtServer = null;
    player.pause();

    final item = _state?.current;
    _startJob = Job.launch((job) async {
      if (waitForOwnPrepare) await _prepareJob?.join();
      job.check();
      if (_loadedItemId == null || (item != null && _loadedItemId != item.id)) {
        // Missed the prepare (e.g. reconnected): load whatever the room is on now
        if (item == null) return;
        await _loadPaused(job, item, msg.positionMs);
      }
      if (_loadedItemId == null) return; // could not load; sit this one out
      await _runStart(job, msg.startAt, msg.positionMs);
    });
  }

  void _onPause(PauseMessage msg) {
    if (_solo) {
      _updateRoom((s) => s.copyWith(phase: 'paused', epoch: msg.epoch, positionMs: msg.positionMs));
      return;
    }
    if (msg.epoch < _handledEpoch) return;
    _handledEpoch = msg.epoch;
    final by = msg.by;
    if (by != null && by != _snapshot.you) _events.add(PausedEvent(by));
    _updateRoom((s) => s.copyWith(phase: 'paused', epoch: msg.epoch, positionMs: msg.positionMs));
    _cancelPlayback();
    final item = _state?.current;
    _startJob = Job.launch((job) async {
      if (_loadedItemId != null) {
        await job.guard(player.seekTo(msg.positionMs));
      } else if (item != null) {
        await _loadPaused(job, item, msg.positionMs);
      }
    });
  }

  /// The room moved on to the next item. A device that already did so keeps playing, one that is about to do so waits
  /// for its player, and anything else loads the item like a late joiner.
  void _onAdvance(AdvanceMessage msg) {
    if (_solo) {
      _updateRoom(
        (s) => s.copyWith(
          index: msg.index,
          epoch: msg.epoch,
          startedAt: msg.startedAt,
          positionMs: 0,
          phase: 'playing',
        ),
      );
      return;
    }
    if (msg.epoch <= _handledEpoch) return;
    final current = _state;
    if (current == null || msg.index < 0 || msg.index >= current.queue.length) return;
    final item = current.queue[msg.index];
    _handledEpoch = msg.epoch;
    _recoveries = 0;
    final advanced = current.copyWith(
      index: msg.index,
      epoch: msg.epoch,
      startedAt: msg.startedAt,
      positionMs: 0,
      phase: 'playing',
    );
    _state = advanced;
    _update((s) => s.copyWith(state: advanced));

    if (_loadedItemId == item.id) {
      _adopt(msg.startedAt);
    } else if (_preloaded?.id == item.id) {
      // Our player is still finishing the previous item and will move on within moments
      _driftJob?.cancel();
      _startedAtServer = null;
      _pendingAdopt = _PendingAdopt(item.id, msg.startedAt);
      _advanceJob?.cancel();
      _advanceJob = Job.launch((job) async {
        await job.delay(_advanceWait);
        final stuck = _pendingAdopt;
        if (stuck == null) return;
        log('player did not advance in time, loading the item');
        _pendingAdopt = null;
        _cancelPlayback();
        _startJob = Job.launch((j) => _catchUpPlaying(j, item, stuck.startedAt));
      });
    } else {
      _cancelPlayback();
      _startJob = Job.launch((j) => _catchUpPlaying(j, item, msg.startedAt));
    }
  }

  /// The player switched to the preloaded item by itself.
  Future<void> _onLocalAdvance() async {
    final item = _preloaded;
    if (item == null) return;
    _preloaded = null;
    _loadedItemId = item.id;
    if (_solo) {
      _update((s) => s.copyWith(soloItemId: item.id));
      _soloPreload();
      return;
    }
    final pending = _pendingAdopt;
    if (pending != null && pending.itemId == item.id) {
      _adopt(pending.startedAt);
      return;
    }
    if (_startedAtServer == null) return; // not following the room in sync, nothing to report

    final epoch = _handledEpoch;
    _driftJob?.cancel();
    _startedAtServer = null; // the position restarted at zero: the old start time no longer applies
    log("advanced locally to '${item.title}'");

    _advanceJob?.cancel();
    _advanceJob = Job.launch((job) async {
      await job.delay(_advanceReportDelay); // let the position settle so the reported start is accurate
      if (_handledEpoch != epoch || _loadedItemId != item.id) return; // the server answered or moved on
      final startedAt = clock.toServer(nowMs()) - player.positionMs();
      if (player.isPlaying()) send(Wire.advanced(epoch, item.id, startedAt));
      // The server normally answers with an advance message; if it does not (offline), follow our own clock
      await job.delay(_advanceWait);
      if (_handledEpoch == epoch && _startedAtServer == null && _loadedItemId == item.id) {
        log('no answer from the room, following the local start');
        _adopt(clock.toServer(nowMs()) - player.positionMs());
      }
    });
  }

  /// Follows the room's clock for the item the player is on right now.
  void _adopt(int startedAt) {
    _clearPendingAdopt();
    _advanceJob?.cancel();
    _startedAtServer = startedAt;
    _startDriftLoop();
    _syncPreload();
    log("following '${_state?.current?.title}' from server time $startedAt");
  }

  void _clearPendingAdopt() {
    _pendingAdopt = null;
    _advanceJob?.cancel();
  }

  /// Keeps the player's gapless successor equal to the item after the current one, while following the room.
  void _syncPreload() {
    final s = _state;
    // Repeating one item is not gapless: it ends and the server starts it over through a barrier
    final following =
        _startedAtServer != null && s != null && s.current?.id == _loadedItemId && s.repeat != 'one';
    QueueEntry? wanted;
    if (following && s.index + 1 < s.queue.length) wanted = s.queue[s.index + 1];
    if (wanted?.id == _preloaded?.id) return;
    _preloaded = wanted;
    player.setNext(wanted);
  }

  /// The stream broke while we were playing in sync. Reload it and rejoin at the position the room has reached, like a
  /// late joiner. Gives up after a few attempts per epoch.
  void _onPlayerError(Object error) {
    final startedAt = _startedAtServer;
    if (startedAt == null) return; // not playing in sync: prepare deals with its own errors
    final item = _state?.current;
    if (item == null) return;
    if (++_recoveries > _maxRecoveriesPerEpoch) {
      log('player error, giving up after $_maxRecoveriesPerEpoch recoveries: $error');
      // Silent while the room plays on: play tries again (see catchUp)
      _startedAtServer = null;
      _loadedItemId = null;
      _loadFailed(item, error);
      return;
    }
    log('player error, recovering (#$_recoveries): $error');
    _cancelPlayback();
    _startJob = Job.launch((j) => _catchUpPlaying(j, item, startedAt));
  }

  // ------------------------------------------------------------------ playback

  Future<void> _loadPaused(Job job, QueueEntry item, int positionMs) async {
    try {
      _preloaded = null; // preparing replaces the whole playlist
      await job.guard(player.prepare(item, positionMs));
      _loaded(item);
    } on Cancelled {
      rethrow;
    } catch (e) {
      log('load failed: $e');
      _loadedItemId = null;
      _loadFailed(item, e);
    }
  }

  void _loaded(QueueEntry item) {
    _loadedItemId = item.id;
    _reportedFailure = null;
  }

  /// Tells the person, once for each item, that this device could not load it: the room may play on without it.
  void _loadFailed(QueueEntry item, Object error) {
    if (_reportedFailure == item.id) return;
    _reportedFailure = item.id;
    _events.add(LoadFailedEvent(item.title, LoadFailure.of(error)?.reason));
  }

  /// Play was pressed while the room plays a song this device does not have: load it again and join in where the room
  /// is, instead of pressing play on an empty player. Returns false when this device has the song, so that play just
  /// resumes it.
  bool catchUp() {
    if (_solo || _loadedItemId != null) return false;
    final s = _state;
    final item = s?.current;
    if (s == null || item == null || s.phase != 'playing') return false;
    if (_startJob?.isActive == true || _prepareJob?.isActive == true) return true;
    _reportedFailure = null; // a new try by hand is told about again if it fails
    player.refresh(item.videoId); // the address that failed may be what is wrong
    log('play pressed with nothing loaded, catching up with the room');
    _startJob = Job.launch((j) => _catchUpPlaying(j, item, s.startedAt));
    return true;
  }

  /// The item is already loaded (e.g. after a reconnect): realign to the room's clock and make sure it plays.
  Future<void> _resumeLoaded(Job job, QueueEntry item, int startedAt) async {
    if (!player.isPlaying() && !_held) {
      final target = clock.toServer(nowMs()) - startedAt + _seekCostMs;
      await job.guard(player.seekTo(target < 0 ? 0 : target));
      player.play();
    }
    _loadedItemId = item.id;
    _adopt(startedAt);
  }

  /// Joins a room that is already playing: load, then start at whatever position it has reached. If loading fails
  /// (typically no network yet) it tries again every few seconds until a newer message cancels this job.
  Future<void> _catchUpPlaying(Job job, QueueEntry item, int startedAt) async {
    var attempt = 0;
    while (true) {
      final guessed = clock.toServer(nowMs()) - startedAt + _catchUpLoadGuessMs;
      await _loadPaused(job, item, guessed < 0 ? 0 : guessed);
      if (_loadedItemId != null) break;
      if (++attempt >= _catchUpMaxAttempts) {
        log("giving up loading '${item.title}' after $attempt attempts");
        return;
      }
      await job.delay(_catchUpRetry);
    }
    final targetServer = clock.toServer(nowMs()) + _catchUpLeadMs;
    final position = targetServer - startedAt;
    await _runStart(job, targetServer, position < 0 ? 0 : position);
  }

  /// Plays position [positionMs] at server time [startAtServer]; if that moment has passed, skips ahead.
  Future<void> _runStart(Job job, int startAtServer, int positionMs) async {
    final startLocal = clock.toLocal(startAtServer);
    if (startLocal - nowMs() > _minTimeToAlignMs) {
      await job.guard(player.seekTo(positionMs + startBiasMs));
      final wait = startLocal - nowMs();
      if (wait > 0) await job.delay(Duration(milliseconds: wait));
      if (!_held) player.play();
      log('${_held ? 'held, not playing' : 'play()'} at scheduled time, position $positionMs');
    } else {
      final late = nowMs() - startLocal;
      final target = positionMs + (late < 0 ? 0 : late) + _seekCostMs + startBiasMs;
      await job.guard(player.seekTo(target));
      if (!_held) player.play();
      log('${_held ? 'held, not playing' : 'play()'} late by ${late}ms, skipped to $target');
    }
    drift.reset();
    player.setSpeed(1);
    _startedAtServer = startAtServer - positionMs;
    _learnBias = !_held;
    _startDriftLoop();
    _syncPreload();
  }

  void _startDriftLoop() {
    _driftJob?.cancel();
    _driftJob = Job.launch((job) async {
      var settleUntil = 0;
      var tick = 0;
      var playingTicks = 0;
      _filter.reset(nowMs());
      while (job.isActive) {
        await job.delay(_driftTick);
        final started = _startedAtServer;
        if (started == null) break;
        if (!player.isPlaying()) {
          playingTicks = 0;
          _update((s) => s.copyWith(driftMs: null));
          // Readings from before a stall say nothing about the position after it
          _filter.reset(nowMs(), _snapshot.speed);
          continue; // buffering or paused: nothing meaningful to measure
        }
        if (++playingTicks >= _healthyTicks) _recoveries = 0;
        final now = nowMs();
        final expected = clock.toServer(now) - started + trimMs;
        final driftMs = player.positionMs() - expected;
        _update((s) => s.copyWith(driftMs: driftMs));
        if (now < settleUntil) continue; // let a recent seek settle before measuring again
        _filter.add(now, driftMs);
        final smoothed = _filter.estimate(now);
        if (smoothed == null) continue;
        if (++tick % _logEveryTicks == 0) {
          log(
            'drift=${driftMs}ms smoothed=${smoothed}ms offset=${clock.offsetMs.toInt()}ms rtt=${clock.bestRttMs?.toInt()}ms',
          );
        }
        // A start far from the room (a device that has not learned its speaker's delay yet) is learned from at once
        // and fixed with one seek
        final coldStart = _learnBias && _filter.hasLargeDriftEvidence && smoothed.abs() > _coldStartSeekMs;
        if (coldStart || (_learnBias && _filter.isFull)) _learnStartBias();
        if (!correctionEnabled) continue;
        final trusted = coldStart ||
            (smoothed.abs() > drift.seekThresholdMs ? _filter.hasLargeDriftEvidence : _filter.isFull);
        if (!trusted) continue;

        final action = coldStart ? const DriftSeek() : drift.decide(smoothed);
        switch (action) {
          case DriftNone():
            break;
          case DriftSetSpeed():
            player.setSpeed(action.factor);
            _filter.setSpeed(now, action.factor);
            _update((s) => s.copyWith(speed: action.factor));
            log('drift=${smoothed}ms (smoothed) -> speed ${action.factor}');
          case DriftSeek():
            final before = nowMs();
            // Aim a little ahead: the seek itself takes time
            final target = clock.toServer(before) - started + _seekCostMs + trimMs;
            _learnBias = false; // a corrective seek muddies what the plain start looked like
            await job.guard(player.seekTo(target));
            _seekCostMs = (nowMs() - before).clamp(50, 1000);
            drift.reset();
            player.setSpeed(1);
            _filter.reset(nowMs());
            _update((s) => s.copyWith(speed: 1));
            settleUntil = nowMs() + _settleAfterSeekMs;
            log('drift=${smoothed}ms (smoothed) -> seek to $target (took ${_seekCostMs}ms)');
        }
      }
    });
  }

  /// The first full window after a plain start shows how far off that start was; fold it into the bias.
  void _learnStartBias() {
    _learnBias = false;
    final residual = _filter.uncorrectedMean();
    if (residual == null) return;
    final updated = (startBiasMs - residual * _biasLearningRate).toInt().clamp(-_maxBiasMs, _maxBiasMs);
    log('start was ${residual.toInt()}ms off, start bias $startBiasMs -> ${updated}ms');
    startBiasMs = updated;
    onStartBiasLearned?.call(updated);
  }

  void _cancelPlayback() {
    _learnBias = false;
    _prepareJob?.cancel();
    _startJob?.cancel();
    _driftJob?.cancel();
    _clearPendingAdopt();
    _startedAtServer = null;
    player.pause();
    player.setSpeed(1);
    drift.reset();
    _update((s) => s.copyWith(driftMs: null, speed: 1));
  }

  /// Below this much time to the scheduled start there is no point in seeking first.
  static const _minTimeToAlignMs = 120;
  static const _driftTick = Duration(milliseconds: 500);
  static const _logEveryTicks = 2; // every second
  static const _settleAfterSeekMs = 1500;
  static const _catchUpLoadGuessMs = 2000;
  static const _catchUpLeadMs = 400;
  static const _catchUpRetry = Duration(seconds: 5);
  static const _catchUpMaxAttempts = 60; // about five minutes plus the time each attempt takes

  /// Continuous playing this long counts as healthy again: earlier recoveries are forgotten.
  static const _healthyTicks = 60;
  static const _maxRecoveriesPerEpoch = 5;
  static const _biasLearningRate = 0.8;
  static const _maxBiasMs = 800;

  /// A start this far off the room is fixed with a seek at once, see the drift loop.
  static const _coldStartSeekMs = 200;

  /// After moving to the next item by itself, wait this long before reporting when it started.
  static const _advanceReportDelay = Duration(seconds: 1);

  /// How long to wait for the room's answer, or for our own player, around a gapless advance.
  static const _advanceWait = Duration(seconds: 4);

  /// Like most players: "previous" restarts the song unless it has only just begun.
  static const _prevRestartsAfterMs = 3000;
}

class _PendingAdopt {
  const _PendingAdopt(this.itemId, this.startedAt);
  final String itemId;
  final int startedAt;
}
