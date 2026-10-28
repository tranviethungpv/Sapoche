import 'dart:async';
import 'dart:math';

import '../models.dart';
import 'job.dart';
import 'player_port.dart';
import 'wire.dart';

/// What is kept of the personal queue between runs.
class SavedQueue {
  const SavedQueue({
    this.queue = const [],
    this.index = 0,
    this.repeat = 'off',
    this.positionMs = 0,
    this.finished = false,
    this.shuffle = false,
    this.shuffleOrder = const [],
  });

  final List<QueueEntry> queue;
  final int index;
  final String repeat;

  /// Where the current item resumes.
  final int positionMs;
  final bool finished;

  /// Whether shuffle is on, and the order the queue had when it went on.
  final bool shuffle;
  final List<String> shuffleOrder;

  Map<String, Object?> toJson() => {
    'queue': [
      for (final e in queue)
        {
          'id': e.id,
          'videoId': e.videoId,
          'title': e.title,
          'artist': e.artist,
          'thumb': e.thumb,
          'durMs': e.durMs,
          'addedBy': e.addedBy,
          'auto': e.auto,
        },
    ],
    'index': index,
    'repeat': repeat,
    'positionMs': positionMs,
    'finished': finished,
    'shuffle': shuffle,
    'shuffleOrder': shuffleOrder,
  };

  /// What was written down, or null when it is no queue this app wrote.
  static SavedQueue? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return SavedQueue(
        queue: [for (final e in json['queue'] as List<dynamic>? ?? const []) QueueEntry.fromJson(e as Map<String, dynamic>)],
        index: (json['index'] as num?)?.toInt() ?? 0,
        repeat: json['repeat'] as String? ?? 'off',
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        finished: json['finished'] as bool? ?? false,
        shuffle: json['shuffle'] as bool? ?? false,
        shuffleOrder: [for (final id in json['shuffleOrder'] as List<dynamic>? ?? const []) id as String],
      );
    } on Object {
      return null;
    }
  }
}

class LocalSnapshot {
  const LocalSnapshot({
    this.queue = const [],
    this.index = 0,
    this.repeat = 'off',
    this.shuffle = false,
    this.finished = false,
    this.loading = false,
  });

  final List<QueueEntry> queue;
  final int index;

  /// off, all or one, like the room's repeat.
  final String repeat;

  /// What is still to come is mixed, and stays mixed as songs are added; off puts the songs back in their order.
  final bool shuffle;

  /// The queue ran out: nothing is playing, and play starts it again from the top.
  final bool finished;

  /// The current song is on its way to play: the screen shows that something is happening before it is heard.
  final bool loading;

  QueueEntry? get current => index >= 0 && index < queue.length ? queue[index] : null;

  LocalSnapshot copyWith({List<QueueEntry>? queue, int? index, String? repeat, bool? shuffle, bool? finished, bool? loading}) =>
      LocalSnapshot(
        queue: queue ?? this.queue,
        index: index ?? this.index,
        repeat: repeat ?? this.repeat,
        shuffle: shuffle ?? this.shuffle,
        finished: finished ?? this.finished,
        loading: loading ?? this.loading,
      );
}

/// What the person should be told about a song: what happened ([kind]) and to which ([title]).
class Problem {
  const Problem(this.kind, [this.title = '']);
  final ProblemKind kind;
  final String title;
}

enum ProblemKind {
  /// Still loading after a while: the network is slow.
  slow('load_slow'),

  /// Could not load it: the device has no network. Play tries again.
  offline('load_offline'),

  /// It cannot be played, or it kept breaking: the next song plays instead.
  skipped('load_skipped'),

  /// YouTube will not play it, and nothing was skipped to (too many such songs in a row).
  unplayable('load_unplayable'),

  /// Could not load it, for some other reason. Play tries again.
  failed('load_failed'),
  queueFull('queue_full');

  const ProblemKind(this.code);

  /// How the screen knows it.
  final String code;
}

/// The songs of [tracks] worth adding to [queue], whose song at [index] is the one playing: those not already waiting in
/// it (playing now or still to come) and not repeated within [tracks]. A song that was played already may be added
/// again, and so may one that autoplay lined up: the room takes that one off. Mirrors Queues.kt.
List<TrackRef> freshTracks(List<TrackRef> tracks, List<QueueEntry> queue, int index) {
  final seen = <String>{};
  final from = index < 0 ? 0 : index;
  for (var i = from; i < queue.length; i++) {
    if (i == from || !queue[i].auto) seen.add(queue[i].videoId);
  }
  return [
    for (final t in tracks)
      if (seen.add(t.videoId)) t,
  ];
}

/// The queue a person listens to outside a room: an ordinary music player's queue that lives on this device and
/// survives restarts. It drives the same [PlayerPort] as [GroupSession] and never talks to the server. Only one of the
/// two owns the player at a time; [attach] and [detach] hand it over. Mirrors LocalSession.kt and LocalSession.swift.
class LocalSession {
  LocalSession({
    required this.player,
    SavedQueue? saved,
    required this.persist,
    this.problem = _ignoreProblem,
    this.log = _ignore,
    this.onQueueEnd = _ignoreEnd,
    String Function()? newId,
    Random? random,
  }) : _random = random ?? Random(),
       _newId = newId ?? (() => _randomId(random ?? Random.secure())),
       _snapshot = _restore(saved),
       _pendingPositionMs = saved == null || saved.finished ? 0 : saved.positionMs,
       _shuffleOrder = saved?.shuffleOrder ?? const [];

  static void _ignore(String _) {}
  static void _ignoreProblem(Problem _) {}
  static void _ignoreEnd(QueueEntry _) {}

  static String _randomId(Random random) =>
      [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  final PlayerPort player;

  /// Called whenever what should be remembered changed.
  final void Function(SavedQueue saved) persist;

  /// Something the person should be told, e.g. a song that would not load.
  final void Function(Problem problem) problem;
  final void Function(String line) log;

  /// The queue ran out of songs after the item (it played through, or next was pressed on the last one).
  final void Function(QueueEntry last) onQueueEnd;
  final String Function() _newId;
  final Random _random;

  LocalSnapshot _snapshot;
  LocalSnapshot get snapshot => _snapshot;
  final _changes = StreamController<LocalSnapshot>.broadcast(sync: true);
  Stream<LocalSnapshot> get changes => _changes.stream;

  void _update(LocalSnapshot Function(LocalSnapshot s) change) {
    _snapshot = change(_snapshot);
    _changes.add(_snapshot);
  }

  /// Queue item loaded in the player; null after a restart until something is played.
  String? _loadedId;

  /// Where the current item resumes once it is loaded.
  int _pendingPositionMs;

  /// The ids of the queue in the order it had when shuffle went on: what turning it off goes back to.
  List<String> _shuffleOrder;

  /// Item handed to the player as the gapless successor of the loaded one.
  QueueEntry? _preloaded;
  Job? _job;

  /// Reloads used on the current item; stops endless retry loops on a broken stream.
  int _recoveries = 0;

  /// Songs skipped in a row because they cannot be played; when YouTube breaks for every song, skipping stops.
  int _skippedInARow = 0;

  /// Whether the item being loaded starts playing once it is ready; play and pause during a load only flip this.
  bool _playOnLoad = false;

  /// Songs whose last load was said to be slow or failed: loading one again starts from a new address.
  final _stuckVideoIds = <String>{};

  /// Position to show for the current item while nothing is loaded (after a restart), else null: the player knows
  /// better then.
  int? get restoredPositionMs => _loadedId == null && _snapshot.current != null ? _pendingPositionMs : null;

  /// Takes the player over: from now on its endings and errors are ours. Loads nothing.
  void attach() {
    // Only the end of a song this session loaded counts: a player that has nothing also reports "ended"
    player.onEnded = () {
      if (_loadedId != null) _step(1, auto: true);
    };
    player.onAdvanced = _onAdvanced;
    player.onError = _onPlayerError;
  }

  /// A room takes the player: silence it, but remember where this queue stood so it can be picked up again.
  void detach() {
    _job?.cancel();
    if (_loadedId != null) _pendingPositionMs = player.positionMs();
    _loadedId = null;
    _preloaded = null;
    player.stop();
    _update((s) => s.copyWith(loading: false));
    save();
  }

  // ------------------------------------------------------------------ transport

  void play() {
    final s = _snapshot;
    if (_loadedId == null && _job?.isActive == true) {
      // Asked twice (a button and the media session both do): the item is on its way, do not start over
      _playOnLoad = true;
      _update((s) => s.copyWith(loading: true));
    } else if (_loadedId != null) {
      player.play();
    } else if (s.queue.isEmpty) {
      return;
    } else if (s.finished) {
      // After the last song, play means "again": from the top of the list
      _load(s.queue[0], 0, play: true);
    } else {
      _load(s.queue[s.index], _pendingPositionMs, play: true);
    }
  }

  void pause() {
    _playOnLoad = false;
    player.pause();
    _update((s) => s.copyWith(loading: false));
    save();
  }

  void seek(int positionMs) {
    final target = positionMs < 0 ? 0 : positionMs;
    if (_loadedId == null) {
      _pendingPositionMs = target;
      return;
    }
    player.seekTo(target);
  }

  void next() => _step(1, auto: false);

  /// Restarts this song, or goes to the one before it when it has only just begun.
  void prev() {
    if (_loadedId != null && player.positionMs() > _prevRestartsAfterMs) {
      seek(0);
    } else {
      _step(-1, auto: false);
    }
  }

  void jump(String id) {
    for (final e in _snapshot.queue) {
      if (e.id == id) {
        _load(e, 0, play: true);
        return;
      }
    }
  }

  // ------------------------------------------------------------------ queue

  /// Adds songs at the end, or right after the current one with [next]. With nothing to play, the first one starts. A
  /// song that is waiting in the queue already is left out.
  void add(List<TrackRef> tracks, {required bool next}) {
    final s = _snapshot;
    final startNow = s.queue.isEmpty || s.finished;
    final fresh = freshTracks(tracks, s.queue, s.finished ? s.queue.length : s.index);
    final room = maxQueue - s.queue.length;
    if (fresh.isNotEmpty && room <= 0) {
      problem(const Problem(ProblemKind.queueFull));
      return;
    }
    final items = [
      for (final t in fresh.take(room < 0 ? 0 : room))
        QueueEntry(id: _newId(), videoId: t.videoId, title: t.title, artist: t.artist, thumb: t.thumb, durMs: t.durMs, addedBy: ''),
    ];
    if (items.isEmpty) return;

    final at = next && !startNow ? s.index + 1 : s.queue.length;
    final queue = [...s.queue]..insertAll(at, items);
    if (s.shuffle && !next && !startNow) {
      // Mixed in among what is to come instead of waiting behind it
      queue.removeRange(at, queue.length);
      for (final item in items) {
        queue.insert(s.index + 1 + _random.nextInt(queue.length - s.index), item);
      }
    }
    _update((s) => s.copyWith(queue: queue));
    if (startNow) {
      _load(items.first, 0, play: true);
    } else {
      _preload();
    }
    save();
  }

  void remove(String id) {
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == id);
    if (at < 0) return;
    final queue = [...s.queue]..removeAt(at);
    if (at < s.index) {
      _update((s) => s.copyWith(queue: queue, index: s.index - 1));
    } else if (at > s.index) {
      _update((s) => s.copyWith(queue: queue));
    } else if (queue.isEmpty) {
      _stopPlayer();
      _update((s) => LocalSnapshot(repeat: s.repeat, shuffle: s.shuffle));
    } else if (at < queue.length) {
      // The next song takes the place of the one removed, and plays if that one was playing
      final play = _loadedId == id && player.isPlaying();
      _update((s) => s.copyWith(queue: queue));
      if (_loadedId == id) {
        _load(queue[at], 0, play: play);
      } else {
        _pendingPositionMs = 0;
      }
    } else {
      _stopPlayer();
      _update((s) => s.copyWith(queue: queue, index: queue.length - 1, finished: true));
    }
    _preload();
    save();
  }

  /// Puts [track], another release of the same song (its video for its audio, or back), in place of the item [id]. If
  /// that item is loaded, the new release takes over from the same moment, playing if it was playing.
  void swap(String id, TrackRef track) {
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == id);
    if (at < 0 || s.queue[at].videoId == track.videoId) return;
    final old = s.queue[at];
    final item = QueueEntry(
      id: old.id,
      videoId: track.videoId,
      title: track.title,
      artist: track.artist,
      thumb: track.thumb,
      durMs: track.durMs,
      addedBy: old.addedBy,
      auto: old.auto,
    );
    _update((s) => s.copyWith(queue: [...s.queue]..[at] = item));
    if (_loadedId == id) {
      final position = player.positionMs();
      // A player that is buffering does not report playing, but the person did not pause it
      _load(item, item.durMs > 0 && position > item.durMs ? item.durMs : position, play: player.isPlaying() || _playOnLoad);
    } else {
      _preload();
    }
    save();
  }

  void move(String id, int toIndex) {
    final s = _snapshot;
    final from = s.queue.indexWhere((e) => e.id == id);
    if (from < 0) return;
    final currentId = s.current?.id;
    final queue = [...s.queue];
    final moved = queue.removeAt(from);
    queue.insert(toIndex.clamp(0, queue.length), moved);
    final index = currentId == null ? 0 : max(0, queue.indexWhere((e) => e.id == currentId));
    _update((s) => s.copyWith(queue: queue, index: index));
    _preload();
    save();
  }

  /// Takes up to [count] of the oldest songs off the queue, the ones already played, to make room at the end: never the
  /// song playing, and never one still to come. Once the queue has finished all of it has been played.
  void dropPlayed(int count) {
    final s = snapshot;
    final drop = min(count, s.finished ? s.queue.length : s.index);
    if (drop <= 0) return;
    _update((s) => s.copyWith(queue: s.queue.sublist(drop), index: max(s.index - drop, 0)));
    save();
  }

  void clear() {
    _stopPlayer();
    _skippedInARow = 0; // a new list is a new start
    _update((s) => LocalSnapshot(repeat: s.repeat, shuffle: s.shuffle));
    save();
  }

  /// Mixes up what is still to come, so the song playing carries on. Once the queue has finished it mixes the whole
  /// list and plays from the top: the way to hear it again in a new order.
  void shuffle() {
    final s = _snapshot;
    if (s.queue.length < 2) return;
    final queue = [...s.queue];
    if (s.finished) {
      queue.shuffle(_random);
      _update((s) => s.copyWith(queue: queue));
      _load(queue[0], 0, play: true);
    } else {
      final rest = queue.sublist(s.index + 1)..shuffle(_random);
      queue.replaceRange(s.index + 1, queue.length, rest);
      _update((s) => s.copyWith(queue: queue));
      _preload();
    }
    save();
  }

  /// Shuffle as a mode, like the room's: on remembers the order and mixes what is still to come; off puts those songs
  /// back in that order, with the ones added meanwhile after them.
  void setShuffle(bool on) {
    final s = _snapshot;
    if (on == s.shuffle) return;
    final queue = [...s.queue];
    final first = s.finished ? 0 : s.index + 1;
    if (on) {
      _shuffleOrder = [for (final e in queue) e.id];
      // After the queue finished only the mode is set: the list is mixed when it is played again
      if (!s.finished && first < queue.length) {
        final rest = queue.sublist(first)..shuffle(_random);
        queue.replaceRange(first, queue.length, rest);
      }
    } else {
      final rank = {for (final (i, id) in _shuffleOrder.indexed) id: i};
      if (first < queue.length) {
        final rest = queue.sublist(first);
        // Those that had a place go back to it; the ones added meanwhile follow them in their own order
        final placed = rest.where((e) => rank.containsKey(e.id)).toList()..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
        queue.replaceRange(first, queue.length, [...placed, ...rest.where((e) => !rank.containsKey(e.id))]);
      }
      _shuffleOrder = const [];
    }
    _update((s) => s.copyWith(shuffle: on, queue: queue));
    _preload();
    save();
  }

  void setRepeat(String mode) {
    if (mode != 'off' && mode != 'all' && mode != 'one') return;
    if (mode == _snapshot.repeat) return;
    _update((s) => s.copyWith(repeat: mode));
    _preload();
    save();
  }

  /// Writes down the queue and where it stands; called on every change and when playback stops.
  void save() {
    final s = _snapshot;
    final position = _loadedId != null ? player.positionMs() : _pendingPositionMs;
    persist(SavedQueue(queue: s.queue, index: s.index, repeat: s.repeat, positionMs: position, finished: s.finished, shuffle: s.shuffle, shuffleOrder: _shuffleOrder));
  }

  // ------------------------------------------------------------------ playing

  /// Moves [delta] items along the queue; at the ends it wraps when repeating all, and otherwise stops.
  void _step(int delta, {required bool auto}) {
    final s = _snapshot;
    if (s.queue.isEmpty) return;
    var target = s.finished && delta < 0 ? s.index : s.index + delta;
    if (auto && s.repeat == 'one') target = s.index;
    if (target >= s.queue.length) target = s.repeat == 'all' ? 0 : -1;
    if (target < 0) {
      if (delta < 0) {
        target = 0;
      } else {
        return _finish();
      }
    }
    _load(s.queue[target], 0, play: true);
  }

  /// Ran out of songs: nothing is current until play starts the list again.
  void _finish() {
    final last = _snapshot.queue.isEmpty ? null : _snapshot.queue.last;
    _stopPlayer();
    _update((s) => s.copyWith(index: s.queue.length - 1, finished: true));
    save();
    if (last != null) onQueueEnd(last);
  }

  void _stopPlayer() {
    _job?.cancel();
    player.stop();
    _loadedId = null;
    _preloaded = null;
    _pendingPositionMs = 0;
    _update((s) => s.copyWith(loading: false));
  }

  void _load(QueueEntry item, int positionMs, {required bool play}) {
    // The tries are counted for the song, not its place: a new song where the last one was starts from none
    if (item.id != _loadedId) _recoveries = 0;
    _job?.cancel();
    _preloaded = null;
    _loadedId = null;
    final at = _snapshot.queue.indexWhere((e) => e.id == item.id);
    if (at < 0) return;
    // The person sees the new song at once, and that it is on its way, not only when it has loaded
    _update((s) => s.copyWith(index: at, finished: false, loading: play));
    _playOnLoad = play;
    final again = _stuckVideoIds.contains(item.videoId);
    _job = Job.launch((job) async {
      // A load that takes long is said to be slow, so that waiting does not look like nothing happening
      final slow = Job.launch((j) async {
        await j.delay(_slowLoad);
        if (_playOnLoad) {
          _stuckVideoIds.add(item.videoId);
          problem(Problem(ProblemKind.slow, item.title));
        }
      });
      try {
        if (again) player.refresh(item.videoId);
        await job.guard(player.prepare(item, positionMs));
        slow.cancel();
        _stuckVideoIds.remove(item.videoId);
        _loadedId = item.id;
        _pendingPositionMs = 0;
        _skippedInARow = 0;
        _update((s) => s.copyWith(loading: false));
        if (_playOnLoad) player.play();
        _preload();
        save();
      } on Cancelled {
        slow.cancel();
        rethrow;
      } catch (e) {
        slow.cancel();
        _stuckVideoIds.add(item.videoId);
        log("could not load '${item.title}': $e");
        // Nothing goes on loading in the background, and nothing starts later by itself
        player.stop();
        _pendingPositionMs = positionMs;
        _update((s) => s.copyWith(loading: false));
        _loadFailed(item, e);
      }
    });
  }

  /// Tells the person why [item] did not load. A song YouTube will not play is skipped, as music apps do, but only a few
  /// in a row: when every song fails, YouTube changed something, and running through the queue would not help.
  void _loadFailed(QueueEntry item, Object error) {
    switch (LoadFailure.of(error)?.reason) {
      case LoadReason.offline:
        problem(Problem(ProblemKind.offline, item.title));
      case LoadReason.unplayable:
        if (++_skippedInARow < _maxSkippedInARow) {
          problem(Problem(ProblemKind.skipped, item.title));
          _step(1, auto: false);
        } else {
          _skippedInARow = 0;
          problem(Problem(ProblemKind.unplayable, item.title));
        }
      case null:
        problem(Problem(ProblemKind.failed, item.title));
    }
  }

  /// Keeps the gapless successor equal to the song after the one loaded.
  void _preload() {
    final s = _snapshot;
    QueueEntry? wanted;
    if (_loadedId != null && s.current?.id == _loadedId && s.repeat != 'one' && s.index + 1 < s.queue.length) {
      wanted = s.queue[s.index + 1];
    }
    if (wanted?.id == _preloaded?.id) return;
    _preloaded = wanted;
    player.setNext(wanted);
  }

  /// The player moved on to the successor by itself.
  void _onAdvanced() {
    final item = _preloaded;
    if (item == null) return;
    final at = _snapshot.queue.indexWhere((e) => e.id == item.id);
    if (at < 0) return;
    _preloaded = null;
    _loadedId = item.id;
    _pendingPositionMs = 0;
    _recoveries = 0;
    _update((s) => s.copyWith(index: at));
    _preload();
    save();
  }

  /// The stream broke while playing: load it again where it stopped, and after a few tries move on.
  void _onPlayerError(Object error) {
    final current = _snapshot.current;
    if (current == null || current.id != _loadedId) return;
    if (++_recoveries > _maxRecoveries) {
      log("player error, giving up on '${current.title}' after $_maxRecoveries tries: $error");
      problem(Problem(ProblemKind.skipped, current.title));
      _recoveries = 0;
      // Not "auto": repeating this one song would load the broken stream again and again
      _step(1, auto: false);
      return;
    }
    log("player error, loading '${current.title}' again (#$_recoveries): $error");
    _load(current, player.positionMs(), play: true);
  }

  static LocalSnapshot _restore(SavedQueue? saved) {
    if (saved == null) return const LocalSnapshot();
    final queue = saved.queue.length > maxQueue ? saved.queue.sublist(0, maxQueue) : saved.queue;
    return LocalSnapshot(
      queue: queue,
      index: saved.index.clamp(0, max(0, queue.length - 1)),
      repeat: saved.repeat == 'all' || saved.repeat == 'one' ? saved.repeat : 'off',
      finished: saved.finished && queue.isNotEmpty,
      shuffle: saved.shuffle,
    );
  }

  /// What the queue outside a room holds. A room's holds 200 (`MAX_QUEUE` in `server/src/room.ts`); `queueMax` in
  /// `room_controller.dart` says both.
  static const maxQueue = 1000;
  static const _maxRecoveries = 3;
  static const _maxSkippedInARow = 3;
  static const _prevRestartsAfterMs = 3000;

  /// A load that takes longer than this is said to be slow.
  static const _slowLoad = Duration(seconds: 8);
}
