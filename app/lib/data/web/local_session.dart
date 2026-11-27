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
    this.queued = const [],
    this.label,
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

  /// Ids of the songs added to the queue by hand that are still waiting after [index].
  final List<String> queued;

  /// Name of the list playing (album, playlist), shown above the songs still to come from it.
  final String? label;

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
          if (e.explicit) 'explicit': true,
          if (e.year != null) 'year': e.year,
        },
    ],
    'index': index,
    'repeat': repeat,
    'positionMs': positionMs,
    'finished': finished,
    'shuffle': shuffle,
    'shuffleOrder': shuffleOrder,
    'queued': queued,
    if (label != null) 'label': label,
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
        queued: [for (final id in json['queued'] as List<dynamic>? ?? const []) id as String],
        label: json['label'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

/// A queue handed to another device, and how many songs were left out because only this device has them.
class Handover {
  const Handover(this.saved, this.dropped);
  final SavedQueue saved;
  final int dropped;
}

const _keepLabel = Object();

class LocalSnapshot {
  const LocalSnapshot({
    this.queue = const [],
    this.index = 0,
    this.repeat = 'off',
    this.shuffle = false,
    this.finished = false,
    this.loading = false,
    this.queued = const {},
    this.label,
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

  /// Ids of the songs added by hand that are still waiting after [index]; they play before the rest of the list.
  final Set<String> queued;

  /// Name of the list playing, or null when there is none.
  final String? label;

  QueueEntry? get current => index >= 0 && index < queue.length ? queue[index] : null;

  LocalSnapshot copyWith({
    List<QueueEntry>? queue,
    int? index,
    String? repeat,
    bool? shuffle,
    bool? finished,
    bool? loading,
    Set<String>? queued,
    Object? label = _keepLabel,
  }) => LocalSnapshot(
    queue: queue ?? this.queue,
    index: index ?? this.index,
    repeat: repeat ?? this.repeat,
    shuffle: shuffle ?? this.shuffle,
    finished: finished ?? this.finished,
    loading: loading ?? this.loading,
    queued: queued ?? this.queued,
    label: identical(label, _keepLabel) ? this.label : label as String?,
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

  /// YouTube will not give the song out (removed, private, blocked where the person is): the next song plays instead.
  skipped('load_skipped'),

  /// The stream kept breaking while it played, which is the connection and not the song: the next song plays instead.
  broken('load_broken'),

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

  /// Songs added by hand that have played (or been skipped past): back can reach them, but repeat all leaves them out.
  final _playedQueued = <String>{};

  /// Item handed to the player as the gapless successor of the loaded one.
  QueueEntry? _preloaded;

  /// A song follows the one loaded, handed to the player to play with no gap.
  bool get hasSuccessor => _preloaded != null;
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
    } else if (s.finished || s.queue.isEmpty) {
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
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == id);
    if (at < 0) return;
    final item = _placeTarget(at);
    _load(item, 0, play: true);
  }

  /// Moves playback to the song at [target] while keeping the three tiers after the new index in order:
  /// songs in [LocalSnapshot.queued] stay right after the song playing unless the jump is into [LocalSnapshot.queued]
  /// itself, in which case the queued songs before [target] are skipped past and become played.
  QueueEntry _placeTarget(int target) {
    final s = _snapshot;
    final chosen = s.queue[target];
    if (s.queued.contains(chosen.id)) {
      final dropped = <String>{
        for (final e in s.queue.take(target + 1))
          if (s.queued.contains(e.id)) e.id,
      };
      _playedQueued.addAll(dropped);
      final newQueued = {...s.queued}..removeAll(dropped);
      final queue = [
        for (final (i, e) in s.queue.indexed)
          i <= target ? e.copyWith(auto: false, queued: false) : e.copyWith(queued: newQueued.contains(e.id)),
      ];
      _update((s) => s.copyWith(queue: queue, index: target, queued: newQueued, finished: false));
      return queue[target];
    }
    final waiting = [
      if (!s.finished)
        for (final e in s.queue.skip(s.index + 1))
          if (s.queued.contains(e.id)) e.copyWith(auto: false, queued: true),
    ];
    final waitingIds = {for (final e in waiting) e.id};
    final rest = [
      for (final e in s.queue)
        if (!waitingIds.contains(e.id)) e,
    ];
    final at = max(0, rest.indexWhere((e) => e.id == chosen.id));
    final before = [for (final e in rest.take(at + 1)) e.copyWith(auto: false, queued: false)];
    final after = [for (final e in rest.skip(at + 1)) e.copyWith(queued: false)];
    final queue = [...before, ...waiting, ...after];
    _update((s) => s.copyWith(queue: queue, index: at, queued: waitingIds, finished: false));
    return queue[at];
  }

  // ------------------------------------------------------------------ queue

  /// Adds songs to the queue. By default ([queued] = true) they go into the "Next in queue" group: at the start of it
  /// with [next], or at the end of it without, and only a song already in that group is left out. With [queued] = false
  /// they extend the list itself (before autoplay songs), or with [auto] = true the autoplay tail at the very end.
  void add(List<TrackRef> tracks, {required bool next, bool queued = true, bool auto = false}) {
    final s = _snapshot;
    final startNow = s.queue.isEmpty || s.finished;
    final List<TrackRef> fresh;
    if (queued && !auto) {
      final seen = <String>{
        if (!startNow)
          for (final e in s.queue.skip(s.index + 1))
            if (s.queued.contains(e.id)) e.videoId,
      };
      fresh = [
        for (final t in tracks)
          if (seen.add(t.videoId)) t,
      ];
    } else {
      fresh = freshTracks(tracks, s.queue, s.finished ? s.queue.length : s.index);
    }
    final room = maxQueue - s.queue.length;
    if (fresh.isNotEmpty && room <= 0) {
      problem(const Problem(ProblemKind.queueFull));
      return;
    }
    final items = [
      for (final (i, t) in fresh.take(room < 0 ? 0 : room).indexed)
        QueueEntry(
          id: _newId(),
          videoId: t.videoId,
          title: t.title,
          artist: t.artist,
          thumb: t.thumb,
          durMs: t.durMs,
          explicit: t.explicit,
          year: t.year,
          addedBy: '',
          auto: auto && !(startNow && i == 0),
          queued: !startNow && queued && !auto,
        ),
    ];
    if (items.isEmpty) return;

    if (startNow) {
      final old = [for (final e in s.queue) e.copyWith(auto: false, queued: false)];
      final queue = [...old, ...items];
      if (s.shuffle && !auto) _shuffleOrder = [..._shuffleOrder, for (final e in items) e.id];
      _update((s) => s.copyWith(queue: queue, index: old.length, queued: const {}, finished: false));
      _load(items.first, 0, play: true);
      save();
      return;
    }

    final queue = [...s.queue];
    var newQueued = s.queued;
    if (queued && !auto) {
      final at = (next ? s.index + 1 : s.index + 1 + s.queued.length).clamp(0, queue.length);
      queue.insertAll(at, items);
      newQueued = {...s.queued, for (final e in items) e.id};
    } else if (auto) {
      queue.addAll(items);
    } else {
      var autoStart = queue.length;
      for (var i = s.index + 1; i < queue.length; i++) {
        if (queue[i].auto) {
          autoStart = i;
          break;
        }
      }
      final contextStart = min(s.index + 1 + s.queued.length, autoStart);
      if (s.shuffle && !next) {
        _shuffleOrder = [..._shuffleOrder, for (final e in items) e.id];
        var end = autoStart;
        for (final item in items) {
          queue.insert(contextStart + _random.nextInt(end - contextStart + 1), item);
          end++;
        }
      } else {
        queue.insertAll(next ? contextStart : autoStart, items);
      }
    }
    _update((s) => s.copyWith(queue: queue, queued: newQueued));
    _preload();
    save();
  }

  /// Makes [tracks], a list the person chose a song from, the active list and plays song [start] of it, keeping any
  /// unplayed songs added by hand ([LocalSnapshot.queued]) right after that song. With shuffle on, that song is first,
  /// the queued songs follow, and the rest of the list is mixed behind them.
  void playList(List<TrackRef> tracks, int start, {String? label}) {
    final s = _snapshot;
    final waiting = [
      if (!s.finished)
        for (final e in s.queue.skip(s.index + 1))
          if (s.queued.contains(e.id)) e.copyWith(auto: false, queued: true),
    ];
    final cap = max(maxQueue - waiting.length, 0);
    final items = [
      for (final t in tracks.take(cap))
        QueueEntry(
          id: _newId(),
          videoId: t.videoId,
          title: t.title,
          artist: t.artist,
          thumb: t.thumb,
          durMs: t.durMs,
          explicit: t.explicit,
          year: t.year,
          addedBy: '',
        ),
    ];
    if (items.isEmpty) return;
    final first = start.clamp(0, items.length - 1);
    final chosen = items[first];
    final shuffle = s.shuffle;
    final List<QueueEntry> queue;
    if (shuffle) {
      final rest = [...items]..removeAt(first)..shuffle(_random);
      queue = [chosen, ...waiting, ...rest];
    } else {
      queue = [...items.sublist(0, first + 1), ...waiting, ...items.sublist(first + 1)];
    }
    final newIndex = shuffle ? 0 : first;
    final newQueued = {for (final e in waiting) e.id};
    _shuffleOrder = shuffle ? [for (final e in items) e.id] : const [];
    _playedQueued.clear();
    _skippedInARow = 0; // a new list is a new start
    final trimmed = label?.trim();
    final cleanLabel = trimmed != null && trimmed.isNotEmpty ? trimmed : null;
    // What plays carries on until the new song is ready, as when a song of the queue is chosen
    _update((s) => s.copyWith(queue: queue, index: newIndex, queued: newQueued, label: cleanLabel, finished: false));
    _load(chosen, 0, play: true);
    save();
  }

  /// Removes only the songs added to the queue by hand ("Next in queue"), leaving the playing list untouched.
  void clearQueued() {
    final s = _snapshot;
    if (s.queued.isEmpty) return;
    final queue = [
      for (final e in s.queue)
        if (!s.queued.contains(e.id)) e,
    ];
    _update((s) => s.copyWith(queue: queue, queued: const {}));
    _preload();
    save();
  }

  void remove(String id) {
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == id);
    if (at < 0) return;
    final queue = [...s.queue]..removeAt(at);
    final newQueued = {...s.queued}..remove(id);
    _playedQueued.remove(id);
    if (_shuffleOrder.isNotEmpty) _shuffleOrder = [for (final e in _shuffleOrder) if (e != id) e];
    if (at < s.index) {
      _update((s) => s.copyWith(queue: queue, index: s.index - 1, queued: newQueued));
    } else if (at > s.index) {
      _update((s) => s.copyWith(queue: queue, queued: newQueued));
    } else if (queue.isEmpty) {
      _stopPlayer();
      _playedQueued.clear();
      _update((s) => LocalSnapshot(repeat: s.repeat, shuffle: s.shuffle));
    } else if (at < queue.length) {
      // The next song takes the place of the one removed, and plays if that one was playing
      final play = _loadedId == id && player.isPlaying();
      final nextItem = queue[at];
      if (newQueued.remove(nextItem.id)) {
        _playedQueued.add(nextItem.id);
      }
      queue[at] = nextItem.copyWith(auto: false, queued: false);
      _update((s) => s.copyWith(queue: queue, queued: newQueued));
      if (_loadedId == id) {
        _load(queue[at], 0, play: play);
      } else {
        _pendingPositionMs = 0;
      }
    } else {
      _stopPlayer();
      _update((s) => s.copyWith(queue: queue, index: queue.length - 1, queued: const {}, finished: true));
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
      explicit: track.explicit,
      year: track.year,
      addedBy: old.addedBy,
      auto: old.auto,
      queued: old.queued,
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

  /// Moves item [id] to [toIndex]. When [queued] is given, the song also joins (or leaves) the "Next in queue" group
  /// according to the group it was dropped into; the three tiers after [LocalSnapshot.index] are always kept in order.
  void move(String id, int toIndex, {bool? queued}) {
    final s = _snapshot;
    final from = s.queue.indexWhere((e) => e.id == id);
    if (from < 0) return;
    final currentId = s.current?.id;
    final list = [...s.queue];
    final moved = list.removeAt(from);
    list.insert(toIndex.clamp(0, list.length), moved);
    final index = currentId == null ? 0 : max(0, list.indexWhere((e) => e.id == currentId));
    final landed = list.indexWhere((e) => e.id == id);
    final newQueued = {...s.queued};
    if (s.finished || landed <= index) {
      newQueued.remove(id);
    } else if (queued == true) {
      newQueued.add(id);
      _playedQueued.remove(id);
      list[landed] = list[landed].copyWith(auto: false, queued: true);
    } else if (queued == false) {
      newQueued.remove(id);
      _playedQueued.remove(id);
      list[landed] = list[landed].copyWith(auto: false, queued: false);
      if (s.shuffle && !_shuffleOrder.contains(id)) _shuffleOrder = [..._shuffleOrder, id];
    }
    final queue = _normalize(list, index, s.finished ? const {} : newQueued, s.finished);
    final keptQueued = <String>{
      if (!s.finished)
        for (final e in queue.skip(index + 1))
          if (newQueued.contains(e.id)) e.id,
    };
    _update((s) => s.copyWith(queue: queue, index: index, queued: keptQueued));
    _preload();
    save();
  }

  /// Takes up to [count] of the oldest songs off the queue, the ones already played, to make room at the end: never the
  /// song playing, and never one still to come. Once the queue has finished all of it has been played.
  void dropPlayed(int count) {
    final s = snapshot;
    final drop = min(count, s.finished ? s.queue.length : s.index);
    if (drop <= 0) return;
    for (final e in s.queue.take(drop)) {
      _playedQueued.remove(e.id);
    }
    _update((s) => s.copyWith(queue: s.queue.sublist(drop), index: max(s.index - drop, 0)));
    save();
  }

  void clear() {
    _stopPlayer();
    _skippedInARow = 0; // a new list is a new start
    _playedQueued.clear();
    _shuffleOrder = const [];
    _update((s) => LocalSnapshot(repeat: s.repeat, shuffle: s.shuffle));
    save();
  }

  /// Mixes up what is still to come of the list, so the song playing carries on and any songs added by hand keep their
  /// order ahead of it. Once the queue has finished it mixes the whole list and plays from the top.
  void shuffle() {
    final s = _snapshot;
    if (s.queue.length < 2) return;
    if (s.finished || s.queue.isEmpty) {
      final queue = [...s.queue]..shuffle(_random);
      _update((s) => s.copyWith(queue: queue));
      _load(queue[0], 0, play: true);
    } else {
      final before = s.queue.sublist(0, s.index + 1);
      final after = s.queue.sublist(s.index + 1);
      final waiting = [for (final e in after) if (s.queued.contains(e.id)) e];
      final context = [for (final e in after) if (!s.queued.contains(e.id) && !e.auto) e]..shuffle(_random);
      final auto = [for (final e in after) if (e.auto) e];
      _update((s) => s.copyWith(queue: [...before, ...waiting, ...context, ...auto]));
      _preload();
    }
    save();
  }

  /// Shuffle as a mode, like the room's: on remembers the order of the list and mixes what is still to come of it
  /// (leaving songs added by hand in the order they were added); off puts the list's songs back in that order.
  void setShuffle(bool on) {
    final s = _snapshot;
    if (on == s.shuffle) return;
    final List<QueueEntry> queue;
    if (s.finished || s.queue.isEmpty) {
      _shuffleOrder = on ? [for (final e in s.queue) if (!s.queued.contains(e.id) && !e.auto) e.id] : const [];
      queue = s.queue;
    } else {
      final before = s.queue.sublist(0, s.index + 1);
      final after = s.queue.sublist(s.index + 1);
      final waiting = [for (final e in after) if (s.queued.contains(e.id)) e];
      final context = [for (final e in after) if (!s.queued.contains(e.id) && !e.auto) e];
      final auto = [for (final e in after) if (e.auto) e];
      final List<QueueEntry> mixed;
      if (on) {
        _shuffleOrder = [for (final e in s.queue) if (!s.queued.contains(e.id) && !e.auto) e.id];
        mixed = [...context]..shuffle(_random);
      } else {
        final rank = {for (final (i, id) in _shuffleOrder.indexed) id: i};
        _shuffleOrder = const [];
        final placed = context.where((e) => rank.containsKey(e.id)).toList()
          ..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
        mixed = [...placed, ...context.where((e) => !rank.containsKey(e.id))];
      }
      queue = [...before, ...waiting, ...mixed, ...auto];
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
    final orderedQueued = [
      for (final e in s.queue.skip(s.index + 1))
        if (s.queued.contains(e.id)) e.id,
    ];
    persist(
      SavedQueue(
        queue: s.queue,
        index: s.index,
        repeat: s.repeat,
        positionMs: position,
        finished: s.finished,
        shuffle: s.shuffle,
        shuffleOrder: _shuffleOrder,
        queued: orderedQueued,
        label: s.label,
      ),
    );
  }

  /// What this queue is now, to hand over to another device (Connect): [save] with the songs of this device's own music
  /// (`local:`) taken out, since the other device has no such file; [Handover.dropped] says how many. The index follows the
  /// song that was playing (the next one when that was one of them), and the queued group and the shuffle order keep only
  /// what is left.
  Handover exportQueue() {
    final s = _snapshot;
    final position = _loadedId != null ? player.positionMs() : _pendingPositionMs;
    final orderedQueued = [
      for (final e in s.queue.skip(s.index + 1))
        if (s.queued.contains(e.id)) e.id,
    ];
    final kept = [for (final e in s.queue) if (!e.isLocal) e];
    SavedQueue of(List<QueueEntry> queue, int index, int positionMs, bool finished, List<String> order, List<String> queued) => SavedQueue(
      queue: queue,
      index: index,
      repeat: s.repeat,
      positionMs: positionMs,
      finished: finished,
      shuffle: s.shuffle,
      shuffleOrder: order,
      queued: queued,
      label: s.label,
    );
    if (kept.length == s.queue.length) return Handover(of(s.queue, s.index, position, s.finished, _shuffleOrder, orderedQueued), 0);
    final keptIds = {for (final e in kept) e.id};
    final current = s.index < s.queue.length ? s.queue[s.index] : null;
    final atCurrent = current != null && keptIds.contains(current.id);
    final int index;
    if (atCurrent) {
      index = kept.indexWhere((e) => e.id == current.id);
    } else {
      // The song that was playing is gone: the next one that stays, from the start
      final next = s.queue.skip(s.index + 1).where((e) => keptIds.contains(e.id)).firstOrNull;
      index = next == null ? max(0, kept.length - 1) : kept.indexWhere((e) => e.id == next.id);
    }
    return Handover(
      of(
        kept,
        index,
        atCurrent ? position : 0,
        s.finished && kept.isNotEmpty,
        [for (final id in _shuffleOrder) if (keptIds.contains(id)) id],
        [for (final id in orderedQueued) if (keptIds.contains(id)) id],
      ),
      s.queue.length - kept.length,
    );
  }

  /// Takes [saved] (what another device handed over) as the whole queue, where it stood: whatever played here stops. With
  /// [play] the song starts from its position; without it the queue waits, as one that was restored does.
  void importQueue(SavedQueue saved, {required bool play}) {
    _stopPlayer();
    _recoveries = 0;
    _skippedInARow = 0;
    _playOnLoad = false;
    _playedQueued.clear();
    _stuckVideoIds.clear();
    _shuffleOrder = saved.shuffleOrder;
    _pendingPositionMs = saved.finished ? 0 : saved.positionMs;
    _update((_) => _restore(saved));
    save();
    if (play) this.play();
  }

  // ------------------------------------------------------------------ playing

  /// Moves [delta] items along the queue; at the ends it wraps when repeating all, and otherwise stops.
  void _step(int delta, {required bool auto}) {
    final s = _snapshot;
    if (s.queue.isEmpty) return;
    if (auto && s.repeat == 'one') {
      _load(s.queue[s.index], 0, play: true);
      return;
    }
    var target = s.finished && delta < 0 ? s.index : s.index + delta;
    if (target >= s.queue.length) {
      if (s.repeat != 'all') return _finish();
      // Repeat all loops the list: songs added by hand that already played once do not play a second time
      final contextOnly = [
        for (final e in s.queue)
          if (!_playedQueued.contains(e.id)) e.copyWith(queued: false),
      ];
      if (contextOnly.isNotEmpty && contextOnly.length < s.queue.length) {
        _playedQueued.clear();
        _update((s) => s.copyWith(queue: contextOnly, index: 0, queued: const {}, finished: false));
        _load(contextOnly[0], 0, play: true);
        return;
      }
      target = 0;
    }
    if (target < 0) {
      if (delta < 0) {
        target = 0;
      } else {
        return _finish();
      }
    }
    final item = _placeTarget(target);
    _load(item, 0, play: true);
  }

  /// Ran out of songs: nothing is current until play starts the list again.
  void _finish() {
    final last = _snapshot.queue.isEmpty ? null : _snapshot.queue.last;
    _stopPlayer();
    _update((s) {
      final clean = [for (final e in s.queue) e.copyWith(auto: false, queued: false)];
      return s.copyWith(queue: clean, index: max(clean.length - 1, 0), queued: const {}, finished: true);
    });
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
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == item.id);
    if (at < 0) return;
    var newQueued = s.queued;
    if (s.queued.contains(item.id)) {
      _playedQueued.add(item.id);
      newQueued = {...s.queued}..remove(item.id);
    }
    final queue = [...s.queue];
    if (queue[at].auto || queue[at].queued) queue[at] = queue[at].copyWith(auto: false, queued: false);
    final loaded = queue[at];
    // The person sees the new song at once, and that it is on its way, not only when it has loaded
    _update((s) => s.copyWith(queue: queue, index: at, queued: newQueued, finished: false, loading: play));
    _playOnLoad = play;
    final again = _stuckVideoIds.contains(loaded.videoId);
    _job = Job.launch((job) async {
      // A load that takes long is said to be slow, so that waiting does not look like nothing happening
      final slow = Job.launch((j) async {
        await j.delay(_slowLoad);
        if (_playOnLoad) {
          _stuckVideoIds.add(loaded.videoId);
          problem(Problem(ProblemKind.slow, loaded.title));
        }
      });
      var retried = false;
      while (true) {
        try {
          if (again || retried) player.refresh(loaded.videoId);
          await job.guard(player.prepare(loaded, positionMs));
          slow.cancel();
          _stuckVideoIds.remove(loaded.videoId);
          _loadedId = loaded.id;
          _pendingPositionMs = 0;
          _skippedInARow = 0;
          _update((s) => s.copyWith(loading: false));
          if (_playOnLoad) player.play();
          _preload();
          save();
          return;
        } on Cancelled {
          slow.cancel();
          rethrow;
        } catch (e) {
          log("could not load '${loaded.title}': $e");
          // Nothing goes on loading in the background, and nothing starts later by itself
          player.stop();
          // A failure that is neither "YouTube will not give it out" nor "no network" is often a blip: the person who
          // wants to hear the song gets one more try from a new stream address before it counts as failed
          if (!retried && LoadFailure.of(e) == null && _playOnLoad) {
            retried = true;
            log("trying '${loaded.title}' once more in ${retryAfter.inMilliseconds}ms");
            try {
              await job.delay(retryAfter);
            } on Cancelled {
              slow.cancel();
              rethrow;
            }
            if (_playOnLoad) continue;
            // Paused meanwhile: there is nothing to tell, and play starts from a new address
            slow.cancel();
            _stuckVideoIds.add(loaded.videoId);
            _pendingPositionMs = positionMs;
            _update((s) => s.copyWith(loading: false));
            return;
          }
          slow.cancel();
          _stuckVideoIds.add(loaded.videoId);
          _pendingPositionMs = positionMs;
          _update((s) => s.copyWith(loading: false));
          _loadFailed(loaded, e);
          return;
        }
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
        if (_playOnLoad && _hasNext && ++_skippedInARow < _maxSkippedInARow) {
          // Tried twice, and the person wants to hear music: on to the next song, which is not why it was to stop
          problem(Problem(ProblemKind.broken, item.title));
          _step(1, auto: false);
        } else {
          _skippedInARow = 0;
          problem(Problem(ProblemKind.failed, item.title));
        }
    }
  }

  /// Whether there is a song to go on to. With none (the last of the list, or the only one) a failure stops: going on would
  /// end the queue, and that starts what follows it (autoplay) because of a network that is not there.
  bool get _hasNext => _snapshot.index + 1 < _snapshot.queue.length || (_snapshot.repeat == 'all' && _snapshot.queue.length > 1);

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
    final s = _snapshot;
    final at = s.queue.indexWhere((e) => e.id == item.id);
    if (at < 0) return;
    _preloaded = null;
    _loadedId = item.id;
    _pendingPositionMs = 0;
    _recoveries = 0;
    var newQueued = s.queued;
    if (s.queued.contains(item.id)) {
      _playedQueued.add(item.id);
      newQueued = {...s.queued}..remove(item.id);
    }
    final queue = [...s.queue];
    if (queue[at].auto || queue[at].queued) queue[at] = queue[at].copyWith(auto: false, queued: false);
    _update((s) => s.copyWith(queue: queue, index: at, queued: newQueued));
    _preload();
    save();
  }

  /// The stream broke while playing: load it again where it stopped, and after a few tries move on.
  void _onPlayerError(Object error) {
    final current = _snapshot.current;
    if (current == null || current.id != _loadedId) return;
    if (++_recoveries > _maxRecoveries) {
      log("player error, giving up on '${current.title}' after $_maxRecoveries tries: $error");
      problem(Problem(ProblemKind.broken, current.title));
      _recoveries = 0;
      // Not "auto": repeating this one song would load the broken stream again and again
      _step(1, auto: false);
      return;
    }
    log("player error, loading '${current.title}' again (#$_recoveries): $error");
    _load(current, player.positionMs(), play: true);
  }

  static List<QueueEntry> _normalize(List<QueueEntry> list, int index, Set<String> queuedIds, bool finished) {
    if (list.isEmpty) return list;
    if (finished) return [for (final e in list) e.copyWith(auto: false, queued: false)];
    final before = [for (final e in list.take(index + 1)) e.copyWith(auto: false, queued: false)];
    final after = list.skip(index + 1);
    final tierQueued = [
      for (final e in after)
        if (queuedIds.contains(e.id)) e.copyWith(auto: false, queued: true),
    ];
    final tierContext = [
      for (final e in after)
        if (!queuedIds.contains(e.id) && !e.auto) e.copyWith(queued: false),
    ];
    final tierAuto = [
      for (final e in after)
        if (!queuedIds.contains(e.id) && e.auto) e.copyWith(queued: false),
    ];
    return [...before, ...tierQueued, ...tierContext, ...tierAuto];
  }

  static LocalSnapshot _restore(SavedQueue? saved) {
    if (saved == null) return const LocalSnapshot();
    final raw = saved.queue.length > maxQueue ? saved.queue.sublist(0, maxQueue) : saved.queue;
    final int index = saved.index.clamp(0, max(0, raw.length - 1));
    final finished = saved.finished && raw.isNotEmpty;
    final afterIds = finished ? const <String>{} : {for (final e in raw.skip(index + 1)) e.id};
    final queued = finished
        ? const <String>{}
        : {
            for (final id in saved.queued)
              if (afterIds.contains(id)) id,
          };
    final queue = _normalize(raw, index, queued, finished);
    final trimmed = saved.label?.trim();
    final label = trimmed != null && trimmed.isNotEmpty && queue.isNotEmpty ? trimmed : null;
    return LocalSnapshot(
      queue: queue,
      index: index,
      repeat: saved.repeat == 'all' || saved.repeat == 'one' ? saved.repeat : 'off',
      finished: finished,
      shuffle: saved.shuffle,
      queued: queued,
      label: label,
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

  /// A song that did not load gets one more try after this long, from a new stream address.
  static const retryAfter = Duration(seconds: 3);
}
