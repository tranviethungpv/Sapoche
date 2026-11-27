import '../backend.dart';
import '../models.dart';

/// What kind of device says so in the list: the icon, and the default of its name.
enum DeviceKind {
  phone,
  tablet,
  tv,
  computer,
  web;

  static DeviceKind parse(String? name) => values.firstWhere((k) => k.name == name, orElse: () => phone);
}

/// What a device says about itself, sealed: only the other devices of the person read it.
class DeviceInfo {
  const DeviceInfo({required this.name, required this.kind, this.app = '', this.inRoom = false});

  final String name;
  final DeviceKind kind;

  /// The version of Sapoche.
  final String app;

  /// The device is in a room: it takes no part in Connect until it leaves (a person's devices and a room's never mix).
  final bool inRoom;

  Map<String, Object?> toJson() => {'name': name, 'kind': kind.name, 'app': app, if (inRoom) 'room': true};

  static DeviceInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return DeviceInfo(name: name, kind: DeviceKind.parse(json['kind'] as String?), app: json['app'] as String? ?? '', inRoom: json['room'] == true);
  }

  DeviceInfo copyWith({String? name, bool? inRoom}) => DeviceInfo(name: name ?? this.name, kind: kind, app: app, inRoom: inRoom ?? this.inRoom);
}

/// A device in the cluster: its public [id], and what it said about itself (null when that could not be opened).
class ConnectDevice {
  const ConnectDevice({required this.id, required this.info, this.you = false});

  final String id;
  final DeviceInfo? info;

  /// This device.
  final bool you;
}

/// A device of the person that is not here now: seen before, [seenAt] on the server's clock (milliseconds).
class RecentDevice {
  const RecentDevice({required this.id, required this.info, required this.seenAt});

  final String id;
  final DeviceInfo? info;
  final int seenAt;
}

/// What the playing device says is happening, often and small (the queue goes apart, see [RemoteQueue]).
class RemoteState {
  const RemoteState({
    required this.rev,
    this.itemId,
    this.current,
    this.phase = 'idle',
    this.index = 0,
    this.repeat = 'off',
    this.shuffle = false,
    this.label,
    this.loading = false,
    this.playing = false,
    this.buffering = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.speed = 1.0,
    this.at = 0,
    this.volume,
    this.video = false,
    this.sleep = const SleepState(),
  });

  /// Counts up on the device that plays; a state that is older than the one held is dropped.
  final int rev;

  /// The queue item that is current, and the song of it (so that a device without the queue can still show it).
  final String? itemId;
  final QueueEntry? current;
  final String phase;
  final int index;
  final String repeat;
  final bool shuffle;
  final String? label;
  final bool loading;
  final bool playing;
  final bool buffering;

  /// Where the song was at [at] (the server's clock, milliseconds).
  final int positionMs;
  final int durationMs;
  final double speed;
  final int at;

  /// The volume of the playing device, 0 to 1; null when it cannot say.
  final double? volume;

  /// The playing device shows the picture of the song.
  final bool video;

  /// The sleep timer of the playing device; [SleepState.endsAt] is on the server's clock.
  final SleepState sleep;

  Map<String, Object?> toJson() => {
    'rev': rev,
    'item': itemId,
    if (current != null) 'cur': _entry(current!),
    'phase': phase,
    'index': index,
    'repeat': repeat,
    'shuffle': shuffle,
    if (label != null) 'label': label,
    'loading': loading,
    'playing': playing,
    'buffering': buffering,
    'pos': positionMs,
    'dur': durationMs,
    'speed': speed,
    'at': at,
    if (volume != null) 'vol': volume,
    'video': video,
    'sleep': {'mode': sleep.mode.name, if (sleep.endsAt != null) 'endsAt': sleep.endsAt!.millisecondsSinceEpoch},
  };

  static RemoteState? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final cur = json['cur'];
      return RemoteState(
        rev: (json['rev'] as num).toInt(),
        itemId: json['item'] as String?,
        current: cur is Map ? QueueEntry.fromJson(cur.cast<String, dynamic>()) : null,
        phase: json['phase'] as String? ?? 'idle',
        index: (json['index'] as num?)?.toInt() ?? 0,
        repeat: json['repeat'] as String? ?? 'off',
        shuffle: json['shuffle'] == true,
        label: json['label'] as String?,
        loading: json['loading'] == true,
        playing: json['playing'] == true,
        buffering: json['buffering'] == true,
        positionMs: (json['pos'] as num?)?.toInt() ?? 0,
        durationMs: (json['dur'] as num?)?.toInt() ?? 0,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        at: (json['at'] as num?)?.toInt() ?? 0,
        volume: (json['vol'] as num?)?.toDouble(),
        video: json['video'] == true,
        sleep: SleepState.fromJson((json['sleep'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
    } on Object {
      return null;
    }
  }

  static Map<String, Object?> _entry(QueueEntry e) => {
    'id': e.id,
    'videoId': e.videoId,
    'title': e.title,
    'artist': e.artist,
    'thumb': e.thumb,
    'durMs': e.durMs,
    'addedBy': e.addedBy,
    if (e.auto) 'auto': true,
    if (e.queued) 'queued': true,
    if (e.explicit) 'explicit': true,
    if (e.year != null) 'year': e.year,
  };

  /// This state with what a command of the person is sure to change, so that a screen can show it before the playing device
  /// answers: the answer (a state with a higher [rev]) takes its place.
  RemoteState guessed({bool? playing, int? positionMs, int? at, String? repeat, bool? shuffle, bool? video}) => RemoteState(
    rev: rev,
    itemId: itemId,
    current: current,
    phase: phase,
    index: index,
    repeat: repeat ?? this.repeat,
    shuffle: shuffle ?? this.shuffle,
    label: label,
    loading: loading,
    playing: playing ?? this.playing,
    buffering: playing == false ? false : buffering,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs,
    speed: speed,
    at: at ?? this.at,
    volume: volume,
    video: video ?? this.video,
    sleep: sleep,
  );

  /// This state, with the song [elapsedMs] later on the clock of whoever reads it.
  RemoteState advanced(int nowServerMs) {
    if (!playing) return this;
    final moved = ((nowServerMs - at) * speed).round();
    final limit = durationMs > 0 ? durationMs : positionMs + moved;
    final position = positionMs + moved;
    return RemoteState(
      rev: rev,
      itemId: itemId,
      current: current,
      phase: phase,
      index: index,
      repeat: repeat,
      shuffle: shuffle,
      label: label,
      loading: loading,
      playing: playing,
      buffering: buffering,
      positionMs: position < 0 ? 0 : (position > limit ? limit : position),
      durationMs: durationMs,
      speed: speed,
      at: nowServerMs,
      volume: volume,
      video: video,
      sleep: sleep,
    );
  }
}

/// The queue of the playing device, as the other devices show it: the songs, and what makes them a queue (the order shuffle
/// began from, what was added by hand). The same JSON the native side hands over (`Backend.queueExport`).
class RemoteQueue {
  const RemoteQueue(this.entries, {this.index = 0});

  final List<QueueEntry> entries;
  final int index;

  /// Reads what [Backend.queueExport] gave: `{queue: [...], index, queued: [ids]}` (the position and the rest are for whoever takes it over).
  static RemoteQueue? fromExport(Object? json) {
    if (json is! Map) return null;
    try {
      final queued = {for (final id in json['queued'] as List<dynamic>? ?? const []) id as String};
      return RemoteQueue(
        [
          for (final e in json['queue'] as List<dynamic>? ?? const [])
            _withQueued(QueueEntry.fromJson((e as Map).cast<String, dynamic>()), queued),
        ],
        index: (json['index'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return null;
    }
  }

  static QueueEntry _withQueued(QueueEntry e, Set<String> queued) => queued.contains(e.id) && !e.queued ? e.copyWith(queued: true) : e;
}

/// A command from a device that controls to the one that plays: the name of a [Backend] call and its arguments, as JSON.
class RemoteCommand {
  const RemoteCommand(this.name, [this.args = const {}]);

  final String name;
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => {'c': name, if (args.isNotEmpty) 'a': args};

  static RemoteCommand? fromJson(Object? json) {
    if (json is! Map || json['c'] is! String) return null;
    return RemoteCommand(json['c'] as String, (json['a'] as Map?)?.cast<String, Object?>() ?? const {});
  }

  /// Does it on [backend], which is the one that plays. What it does not know is left alone.
  Future<void> run(Backend backend) async {
    List<Track> tracks() => [for (final t in args['tracks'] as List<dynamic>? ?? const []) Track.fromMap((t as Map).cast<Object?, Object?>())];
    final source = args['source'] as String? ?? ListenSource.chosen;
    switch (name) {
      case 'play':
        return backend.play();
      case 'pause':
        return backend.pause();
      case 'next':
        return backend.next();
      case 'prev':
        return backend.prev();
      case 'seek':
        return backend.seek((args['ms'] as num).toInt());
      case 'jump':
        return backend.jump(args['id'] as String);
      case 'add':
        return backend.add(
          Track.fromMap((args['track'] as Map).cast<Object?, Object?>()),
          playNext: args['next'] == true,
          source: source,
        );
      case 'addMany':
        return backend.addMany(tracks(), playNext: args['next'] == true, queued: args['queued'] != false, source: source);
      case 'playList':
        return backend.playList(tracks(), start: (args['start'] as num?)?.toInt() ?? 0, label: args['label'] as String?, source: source);
      case 'repeat':
        return backend.setRepeat(Repeat.parse(args['mode'] as String?));
      case 'remove':
        return backend.remove(args['id'] as String);
      case 'move':
        return backend.move(args['id'] as String, (args['to'] as num).toInt(), queued: args['queued'] as bool?);
      case 'swap':
        return backend.swap(args['id'] as String, Track.fromMap((args['track'] as Map).cast<Object?, Object?>()));
      case 'clear':
        return backend.clear();
      case 'clearQueued':
        return backend.clearQueued();
      case 'shuffle':
        return backend.shuffle();
      case 'setShuffle':
        return backend.setShuffle(args['on'] == true);
      case 'volume':
        return backend.setVolume((args['level'] as num).toDouble());
      case 'sleep':
        return backend.setSleep(
          SleepMode.values.firstWhere((m) => m.name == args['mode'], orElse: () => SleepMode.off),
          minutes: (args['minutes'] as num?)?.toInt() ?? 0,
        );
      case 'speed':
        return backend.setPlaybackSpeed((args['speed'] as num).toDouble());
      case 'radio':
        return backend.fillRadio(args['videoId'] as String);
      case 'video':
        return backend.setVideoMode(args['on'] == true);
    }
  }
}
