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

  /// The shape the native side reads a song in.
  Map<String, Object?> toMap() => {
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'thumb': thumb,
    'durMs': durMs,
  };
}

/// Where a song stands on the way to being kept on this phone.
enum DownloadState {
  /// Asked for, waiting its turn or being fetched.
  queued,

  /// A liked song waiting for Wi-Fi and a charger.
  waiting,

  /// On the phone: plays without the network.
  done,
  failed;

  static DownloadState parse(String? name) =>
      DownloadState.values.asNameMap()[name] ?? DownloadState.queued;
}

/// A song on the list of downloads.
class DownloadEntry {
  const DownloadEntry({
    required this.track,
    required this.state,
    this.bytes = 0,
  });

  final Track track;
  final DownloadState state;

  /// Size on the phone once done.
  final int bytes;

  factory DownloadEntry.fromMap(Map<Object?, Object?> map) => DownloadEntry(
    track: Track.fromMap(map),
    state: DownloadState.parse(map['state'] as String?),
    bytes: (map['bytes'] as num?)?.toInt() ?? 0,
  );
}

/// What the songs kept on the phone take, and the settings about them.
class StorageInfo {
  const StorageInfo({
    this.playBytes = 0,
    this.playLimitMb = 256,
    this.downloadBytes = 0,
    this.downloadCount = 0,
    this.autoDownload = false,
  });

  /// Songs played before, kept so that they play again without data.
  final int playBytes;
  final int playLimitMb;

  /// Songs downloaded.
  final int downloadBytes;
  final int downloadCount;

  /// Liked songs are downloaded by themselves on Wi-Fi while charging.
  final bool autoDownload;

  factory StorageInfo.fromMap(Map<Object?, Object?> map) => StorageInfo(
    playBytes: (map['playBytes'] as num?)?.toInt() ?? 0,
    playLimitMb: (map['playLimitMb'] as num?)?.toInt() ?? 256,
    downloadBytes: (map['downloadBytes'] as num?)?.toInt() ?? 0,
    downloadCount: (map['downloadCount'] as num?)?.toInt() ?? 0,
    autoDownload: map['autoDownload'] as bool? ?? false,
  );
}

/// A playlist the person made, as listed: its cover is its first song's picture.
class SavedPlaylist {
  const SavedPlaylist({
    required this.id,
    required this.name,
    this.count = 0,
    this.thumb,
  });

  final int id;
  final String name;
  final int count;
  final String? thumb;

  factory SavedPlaylist.fromMap(Map<Object?, Object?> map) => SavedPlaylist(
    id: (map['id'] as num).toInt(),
    name: map['name'] as String,
    count: (map['count'] as num?)?.toInt() ?? 0,
    thumb: map['thumb'] as String?,
  );
}

/// A song from the history: when it was last heard and how often.
class HistoryEntry {
  const HistoryEntry({required this.track, required this.at, this.plays = 1});

  final Track track;

  /// When it was last heard.
  final DateTime at;
  final int plays;

  factory HistoryEntry.fromMap(Map<Object?, Object?> map) => HistoryEntry(
    track: Track.fromMap(map),
    at: DateTime.fromMillisecondsSinceEpoch((map['at'] as num?)?.toInt() ?? 0),
    plays: (map['plays'] as num?)?.toInt() ?? 1,
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

  /// The song is waiting in the queue: playing now or still to come. One that was played already is not.
  bool isQueued(String videoId) {
    // Outside a room an idle queue has played through
    if (!inRoom && phase == 'idle') return false;
    return queue.skip(index).any((e) => e.videoId == videoId);
  }

  /// [tracks] without those that are waiting in the queue already, and without repeats.
  List<T> fresh<T extends Track>(List<T> tracks) {
    final seen = <String>{};
    return [
      for (final t in tracks)
        if (!isQueued(t.videoId) && seen.add(t.videoId)) t,
    ];
  }

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
    this.autoplay = true,
  });

  /// Name used in the last room, to prefill the field asking for it.
  final String? name;
  final String device;
  final int trimMs;

  /// Address of the room server, where invitation links live.
  final String server;

  /// The music carries on with similar songs when the queue runs out.
  final bool autoplay;

  Profile withAutoplay(bool value) => Profile(
    name: name,
    device: device,
    trimMs: trimMs,
    server: server,
    autoplay: value,
  );

  factory Profile.fromMap(Map<Object?, Object?> map) => Profile(
    name: map['name'] as String?,
    device: map['device'] as String? ?? '',
    trimMs: (map['trimMs'] as num?)?.toInt() ?? 0,
    server: map['server'] as String? ?? '',
    autoplay: map['autoplay'] as bool? ?? true,
  );
}

/// What the sleep timer is set to.
enum SleepMode { off, time, song }

class SleepState {
  const SleepState({this.mode = SleepMode.off, this.endsAt});

  final SleepMode mode;

  /// When the music stops, for [SleepMode.time].
  final DateTime? endsAt;

  bool get on => mode != SleepMode.off;

  factory SleepState.fromJson(Map<String, dynamic> json) {
    final endsAt = (json['endsAt'] as num?)?.toInt();
    return SleepState(
      mode: switch (json['mode']) {
        'time' => SleepMode.time,
        'song' => SleepMode.song,
        _ => SleepMode.off,
      },
      endsAt: endsAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(endsAt),
    );
  }
}

/// How many songs, playlists and listens a backup file holds, or how many of them a restore added.
class BackupCounts {
  const BackupCounts({this.liked = 0, this.playlists = 0, this.listens = 0});

  final int liked;
  final int playlists;
  final int listens;

  bool get isEmpty => liked == 0 && playlists == 0 && listens == 0;

  factory BackupCounts.fromMap(Map<Object?, Object?> map) => BackupCounts(
    liked: (map['liked'] as num?)?.toInt() ?? 0,
    playlists: (map['playlists'] as num?)?.toInt() ?? 0,
    listens: (map['listens'] as num?)?.toInt() ?? 0,
  );
}
