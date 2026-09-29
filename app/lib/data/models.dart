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

/// A playlist found by search: what it is, before its songs are fetched.
class PlaylistRef {
  const PlaylistRef({
    required this.id,
    required this.title,
    this.uploader = '',
    this.thumb,
    this.count = 0,
  });

  final String id;
  final String title;
  final String uploader;
  final String? thumb;

  /// Number of songs, or 0 when YouTube does not say.
  final int count;

  factory PlaylistRef.fromMap(Map<Object?, Object?> map) => PlaylistRef(
    id: map['id'] as String,
    title: map['title'] as String,
    uploader: map['uploader'] as String? ?? '',
    thumb: map['thumb'] as String?,
    count: (map['count'] as num?)?.toInt() ?? 0,
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
  const Member({
    required this.id,
    required this.name,
    required this.ready,
    this.solo = false,
    this.away = false,
    this.owner = false,
  });

  final String id;
  final String name;
  final bool ready;

  /// Listening on their own: the room's play, pause and skip do not move them.
  final bool solo;

  /// Not heard from for a while, probably a dead connection: not counted as listening.
  final bool away;

  /// Can change the room's settings and remove people.
  final bool owner;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: json['id'] as String,
    name: json['name'] as String,
    ready: json['ready'] as bool? ?? false,
    solo: json['solo'] as bool? ?? false,
    away: json['away'] as bool? ?? false,
    owner: json['owner'] as bool? ?? false,
  );
}

/// What guests may do while the owner is in the room.
enum GuestControl {
  /// Everybody controls the room.
  all,

  /// Guests only add songs.
  add;

  static GuestControl parse(String? name) =>
      GuestControl.values.asNameMap()[name] ?? GuestControl.all;
}

/// What the server says about a room before this device joins it.
class RoomInfo {
  const RoomInfo({
    required this.exists,
    this.name,
    this.members = 0,
    this.playing = false,
    this.title,
  });

  /// False when the code was never used or the room has expired.
  final bool exists;
  final String? name;

  /// People who are really there right now.
  final int members;
  final bool playing;

  /// The song the room is on.
  final String? title;

  factory RoomInfo.fromMap(Map<Object?, Object?> map) => RoomInfo(
    exists: map['exists'] as bool? ?? false,
    name: map['name'] as String?,
    members: (map['members'] as num?)?.toInt() ?? 0,
    playing: map['playing'] as bool? ?? false,
    title: map['title'] as String?,
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
    this.solo = false,
    this.soloItemId,
    this.video = false,
    this.videoHeight = 720,
    this.name,
    this.ownerId,
    this.guestControl = GuestControl.all,
  });

  /// Room code, or null when this device is not in a room. Outside a room this describes the
  /// personal queue: the same fields, no members.
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

  /// This device listens on its own: it plays what the person picked here, whatever the room does.
  final bool solo;

  /// The song this device is on while [solo].
  final String? soloItemId;

  /// Songs are played with their picture on this device.
  final bool video;

  /// Tallest picture fetched, in pixels.
  final int videoHeight;

  /// Room name, when it has one.
  final String? name;

  /// The member who owns the room, when it has an owner.
  final String? ownerId;
  final GuestControl guestControl;

  bool get inRoom => room != null;

  /// This device's own player decides what plays: outside a room, or while listening alone.
  bool get ownPlayback => solo || !inRoom;

  bool get iOwn => ownerId != null && ownerId == you;

  /// The owner is here, so what guests may do is limited.
  bool get ownerHere => members.any((m) => m.owner && !m.away);

  /// This device may play, pause, skip and change the queue. The server has the last word.
  bool get canControl => guestControl == GuestControl.all || iOwn || !ownerHere;

  /// Where this device is in the queue: the room's place, or its own while listening alone.
  int get myIndex {
    if (solo && soloItemId != null) {
      final at = queue.indexWhere((e) => e.id == soloItemId);
      if (at >= 0) return at;
    }
    return index;
  }

  QueueEntry? get current =>
      myIndex >= 0 && myIndex < queue.length ? queue[myIndex] : null;
  List<QueueEntry> get upNext =>
      myIndex + 1 < queue.length ? queue.sublist(myIndex + 1) : const [];

  /// People who are really there; someone whose connection went quiet does not count.
  int get listeningCount => members.where((m) => !m.away).length;
  int get awayCount => members.where((m) => m.away).length;

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
    solo: json['solo'] as bool? ?? false,
    soloItemId: json['soloItemId'] as String?,
    video: json['video'] as bool? ?? false,
    videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 720,
    name: json['name'] as String?,
    ownerId: json['ownerId'] as String?,
    guestControl: GuestControl.parse(json['guestControl'] as String?),
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
    this.videoWidth = 0,
    this.videoHeight = 0,
  });

  final bool playing;
  final bool buffering;
  final int positionMs;
  final int durationMs;

  /// How far this device is from the room's position, or null when not playing in sync.
  final int? driftMs;
  final double speed;

  /// Size of the picture being played, or 0 until there is one.
  final int videoWidth;
  final int videoHeight;

  factory PlayerPosition.fromJson(Map<String, dynamic> json) => PlayerPosition(
    playing: json['playing'] as bool? ?? false,
    buffering: json['buffering'] as bool? ?? false,
    positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    driftMs: (json['driftMs'] as num?)?.toInt(),
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
    videoWidth: (json['videoWidth'] as num?)?.toInt() ?? 0,
    videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 0,
  );
}

/// Something the server told this device that the user should see.
class ServerError {
  const ServerError(this.code, this.message);

  final String code;
  final String message;
}

class Profile {
  const Profile({
    this.name,
    this.device = '',
    this.trimMs = 0,
    this.server = '',
  });

  /// Name used in the last room, to prefill the field asking for it.
  final String? name;
  final String device;
  final int trimMs;

  /// Address of the room server, where invitation links live.
  final String server;

  factory Profile.fromMap(Map<Object?, Object?> map) => Profile(
    name: map['name'] as String?,
    device: map['device'] as String? ?? '',
    trimMs: (map['trimMs'] as num?)?.toInt() ?? 0,
    server: map['server'] as String? ?? '',
  );
}
