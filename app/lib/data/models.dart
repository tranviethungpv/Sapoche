/// Plain data the UI works with. The JSON keys are a contract with UiJson.kt on the native side.
library;

/// A song found by search or a pasted link, not yet in the room's queue.
class Track {
  const Track({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.durMs,
    this.thumb,
  });

  final String videoId;
  final String title;
  final String artist;
  final String? thumb;
  final int durMs;

  factory Track.fromMap(Map<Object?, Object?> map) => Track(
    videoId: map['videoId'] as String,
    title: map['title'] as String,
    artist: map['artist'] as String? ?? '',
    thumb: map['thumb'] as String?,
    durMs: (map['durMs'] as num?)?.toInt() ?? 0,
  );
}

/// A song in the room's shared queue.
class QueueEntry extends Track {
  const QueueEntry({
    required this.id,
    required super.videoId,
    required super.title,
    required super.artist,
    required super.durMs,
    required this.addedBy,
    super.thumb,
  });

  final String id;
  final String addedBy;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    id: json['id'] as String,
    videoId: json['videoId'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String? ?? '',
    thumb: json['thumb'] as String?,
    durMs: (json['durMs'] as num?)?.toInt() ?? 0,
    addedBy: json['addedBy'] as String? ?? '',
  );
}

class Member {
  const Member({required this.id, required this.name, required this.ready});

  final String id;
  final String name;
  final bool ready;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: json['id'] as String,
    name: json['name'] as String,
    ready: json['ready'] as bool? ?? false,
  );
}

/// What happens when a song ends.
enum Repeat {
  off,
  all,
  one;

  /// Order of the button: off, then repeat the queue, then repeat this song, then off again.
  Repeat get next => Repeat.values[(index + 1) % Repeat.values.length];

  static Repeat parse(String? name) =>
      Repeat.values.asNameMap()[name] ?? Repeat.off;
}

/// What a pasted link turned out to be: one song, or the songs of a playlist.
class LinkResult {
  const LinkResult({required this.tracks, this.playlistTitle});

  final List<Track> tracks;

  /// Set when the link was a playlist.
  final String? playlistTitle;

  bool get isPlaylist => playlistTitle != null;

  factory LinkResult.fromMap(Map<Object?, Object?> map) => LinkResult(
    playlistTitle: map['title'] as String?,
    tracks: [
      for (final e in map['tracks'] as List<Object?>)
        Track.fromMap(e as Map<Object?, Object?>),
    ],
  );
}

/// State of this device's connection to the room server.
enum Link { none, connecting, connected, reconnecting, closed, unauthorized }

/// What the room looks like right now. Changes when someone adds a song, joins, presses play...
class RoomSnapshot {
  const RoomSnapshot({
    this.room,
    this.link = Link.none,
    this.you,
    this.phase = 'idle',
    this.index = 0,
    this.repeat = Repeat.off,
    this.queue = const [],
    this.members = const [],
    this.trimMs = 0,
  });

  /// Room code, or null when this device is not in a room.
  final String? room;
  final Link link;
  final String? you;

  /// One of idle, preparing, playing, paused.
  final String phase;
  final int index;
  final Repeat repeat;
  final List<QueueEntry> queue;
  final List<Member> members;
  final int trimMs;

  bool get inRoom => room != null;
  QueueEntry? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  List<QueueEntry> get upNext =>
      index + 1 < queue.length ? queue.sublist(index + 1) : const [];

  /// The room wants sound: playing, or about to start once everybody has loaded.
  bool get wantsPlaying => phase == 'playing' || phase == 'preparing';

  Member? get me {
    for (final m in members) {
      if (m.id == you) return m;
    }
    return null;
  }

  String nameOf(String memberId) {
    for (final m in members) {
      if (m.id == memberId) return m.name;
    }
    return '';
  }

  factory RoomSnapshot.fromJson(Map<String, dynamic> json) => RoomSnapshot(
    room: json['room'] as String?,
    link: _link(json['connection'] as String?),
    you: json['you'] as String?,
    phase: json['phase'] as String? ?? 'idle',
    index: (json['index'] as num?)?.toInt() ?? 0,
    repeat: Repeat.parse(json['repeat'] as String?),
    trimMs: (json['trimMs'] as num?)?.toInt() ?? 0,
    queue: [
      for (final e in json['queue'] as List<dynamic>? ?? const [])
        QueueEntry.fromJson(e as Map<String, dynamic>),
    ],
    members: [
      for (final e in json['members'] as List<dynamic>? ?? const [])
        Member.fromJson(e as Map<String, dynamic>),
    ],
  );

  static Link _link(String? name) => switch (name) {
    'connecting' => Link.connecting,
    'connected' => Link.connected,
    'reconnecting' => Link.reconnecting,
    'closed' => Link.closed,
    'unauthorized' => Link.unauthorized,
    _ => Link.none,
  };
}

/// The local player, sampled about once a second and extrapolated in between.
class PlayerPosition {
  const PlayerPosition({
    this.playing = false,
    this.buffering = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.driftMs,
    this.speed = 1.0,
  });

  final bool playing;
  final bool buffering;
  final int positionMs;
  final int durationMs;

  /// How far this device is from the room's position, or null when not playing in sync.
  final int? driftMs;
  final double speed;

  factory PlayerPosition.fromJson(Map<String, dynamic> json) => PlayerPosition(
    playing: json['playing'] as bool? ?? false,
    buffering: json['buffering'] as bool? ?? false,
    positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    driftMs: (json['driftMs'] as num?)?.toInt(),
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
  );
}

/// Something the server told this device that the user should see.
class ServerError {
  const ServerError(this.code, this.message);

  final String code;
  final String message;
}

class Profile {
  const Profile({this.name, this.device = '', this.trimMs = 0});

  /// Name used in the last room, to prefill the welcome screen.
  final String? name;
  final String device;
  final int trimMs;

  factory Profile.fromMap(Map<Object?, Object?> map) => Profile(
    name: map['name'] as String?,
    device: map['device'] as String? ?? '',
    trimMs: (map['trimMs'] as num?)?.toInt() ?? 0,
  );
}
