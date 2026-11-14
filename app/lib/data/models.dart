/// Plain data the UI works with. The JSON keys are a contract with UiJson.kt on the native side.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;

import 'song_key.dart';

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

  /// The song is a music file on this phone, not a YouTube video: it plays from the file and cannot go to a room.
  bool get isLocal => videoId.startsWith(Track.localPrefix);

  /// What the id of a song from a file on this phone starts with; no video id of YouTube has a colon.
  static const localPrefix = 'local:';

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

  /// Not fetched, after tries that did not work.
  failed,

  /// YouTube will not give this song out (removed, private, blocked here, age restricted): trying again at once does not
  /// help, so it is not tried more than once until the person asks.
  unavailable;

  static DownloadState parse(String? name) =>
      DownloadState.values.asNameMap()[name] ?? DownloadState.queued;
}

/// How the run of downloads in hand stands, as the phone tells it: [active] is the song being fetched, null when none is.
/// [total] is what the run took so far and what is still to take. A run that is over keeps its numbers (null [active],
/// [total] above zero) until the next one starts; [idle] is no run at all.
class DownloadBatch {
  const DownloadBatch({
    this.active,
    this.done = 0,
    this.total = 0,
    this.failed = 0,
  });

  static const idle = DownloadBatch();

  final String? active;
  final int done;
  final int total;
  final int failed;

  bool get running => active != null;

  /// The place of the song being fetched among the run's, from 1.
  int get position => (done + failed + 1).clamp(1, total < 1 ? 1 : total);

  @override
  bool operator ==(Object other) =>
      other is DownloadBatch &&
      other.active == active &&
      other.done == done &&
      other.total == total &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(active, done, total, failed);
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

/// Whether the person let this device tell them of the chat while the app is away.
enum NoticePermission {
  granted,
  denied,

  /// Not asked yet, or the browser or phone does not say.
  undecided;

  static NoticePermission parse(Object? name) => values.firstWhere((v) => v.name == name, orElse: () => undecided);
}

/// What this device can do to tell the person of a message in the room's chat while the app is away, and how it is set.
class NotificationInfo {
  const NotificationInfo({
    this.supported = false,
    this.permission = NoticePermission.undecided,
    this.enabled = false,
    this.preview = true,
    this.needsInstall = false,
    this.mutes = const {},
  });

  /// False where nothing can be done (a browser without notifications, a build that does not have them yet): the app
  /// then shows nothing about them.
  final bool supported;
  final NoticePermission permission;

  /// The person turned them on and the device allows them.
  final bool enabled;

  /// The notice shows the message and not only who wrote it.
  final bool preview;

  /// On an iPhone a web page gets notices only once it is on the Home Screen.
  final bool needsInstall;

  /// Until when (milliseconds since 1970) each room, by its code, is kept quiet.
  final Map<String, int> mutes;

  /// Until when [room] is quiet, or null when it is not.
  DateTime? mutedUntil(String? room, {DateTime? now}) {
    final until = mutes[room];
    if (until == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(until);
    return at.isAfter(now ?? DateTime.now()) ? at : null;
  }

  factory NotificationInfo.fromMap(Map<Object?, Object?> map) => NotificationInfo(
    supported: map['supported'] as bool? ?? false,
    permission: NoticePermission.parse(map['permission']),
    enabled: map['enabled'] as bool? ?? false,
    preview: map['preview'] as bool? ?? true,
    needsInstall: map['needsInstall'] as bool? ?? false,
    mutes: {
      for (final e in ((map['mutes'] as Map<Object?, Object?>?) ?? const {}).entries)
        if (e.value is num) e.key as String: (e.value as num).toInt(),
    },
  );
}

/// A playlist the person made, as listed: its cover is its first song's picture.
class SavedPlaylist {
  const SavedPlaylist({
    required this.id,
    required this.name,
    this.count = 0,
    this.thumbs = const [],
    this.folderId,
  });

  final int id;
  final String name;
  final int count;

  /// Pictures of the first songs, up to four, each once: what the cover of the playlist is made of.
  final List<String> thumbs;

  /// The [PlaylistFolder] it is kept in, or null when it is in none.
  final int? folderId;

  factory SavedPlaylist.fromMap(Map<Object?, Object?> map) => SavedPlaylist(
    id: (map['id'] as num).toInt(),
    name: map['name'] as String,
    count: (map['count'] as num?)?.toInt() ?? 0,
    thumbs: [...?(map['thumbs'] as List?)?.cast<String>()],
    folderId: (map['folderId'] as num?)?.toInt(),
  );
}

/// A folder of playlists, as Spotify has them: a playlist is in one at most, and playing the folder plays them all.
class PlaylistFolder {
  const PlaylistFolder({required this.id, required this.name});

  final int id;
  final String name;

  factory PlaylistFolder.fromMap(Map<Object?, Object?> map) => PlaylistFolder(
    id: (map['id'] as num).toInt(),
    name: map['name'] as String,
  );
}

/// A song from the history: when it was last heard and how often.
class HistoryEntry {
  const HistoryEntry({required this.track, required this.at, this.plays = 1, this.source});

  final Track track;

  /// Where the listen came from (see `ListenSource`); null for a row from before sources were kept, which counts as chosen.
  final String? source;

  /// When it was last heard.
  final DateTime at;
  final int plays;

  factory HistoryEntry.fromMap(Map<Object?, Object?> map) => HistoryEntry(
    track: Track.fromMap(map),
    at: DateTime.fromMillisecondsSinceEpoch((map['at'] as num?)?.toInt() ?? 0),
    plays: (map['plays'] as num?)?.toInt() ?? 1,
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
    this.auto = false,
  });

  final String id;
  final String addedBy;

  /// Put on the queue by autoplay, not by a member: it waits behind the songs they chose and goes once played.
  final bool auto;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    id: json['id'] as String,
    videoId: json['videoId'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String? ?? '',
    thumb: json['thumb'] as String?,
    durMs: (json['durMs'] as num?)?.toInt() ?? 0,
    addedBy: json['addedBy'] as String? ?? '',
    auto: json['auto'] == true,
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
    this.av,
    this.app,
    this.weak = false,
  });

  final String id;
  final String name;
  final bool ready;

  /// The device said its network is weak; false from an app or a server older than protocol 20.
  final bool weak;

  /// The version of the app they use, like `1.26.0`; null from an app or a server older than protocol 17.
  final String? app;

  /// Fingerprint of the member's picture; null when they have none. The picture itself is asked for with `avatar.get`.
  final String? av;

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
    av: json['av'] as String?,
    app: json['app'] as String?,
    weak: json['weak'] as bool? ?? false,
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
    this.who = const [],
  });

  /// False when the code was never used or the room has expired.
  final bool exists;
  final String? name;

  /// People who are really there right now.
  final int members;
  final bool playing;

  /// The song the room is on.
  final String? title;

  /// The names of the first few who are there; empty from a server older than protocol 17.
  final List<String> who;

  factory RoomInfo.fromMap(Map<Object?, Object?> map) => RoomInfo(
    exists: map['exists'] as bool? ?? false,
    name: map['name'] as String?,
    members: (map['members'] as num?)?.toInt() ?? 0,
    playing: map['playing'] as bool? ?? false,
    title: map['title'] as String?,
    who: [for (final name in map['who'] as List? ?? const []) '$name'],
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
    this.loading = false,
    this.video = false,
    this.videoHeight = 720,
    this.playbackSpeed = 1.0,
    this.name,
    this.ownerId,
    this.theme,
    this.guestControl = GuestControl.all,
    this.roomAutoplay,
    this.roomWaitWeak,
    this.shuffle,
    this.encrypted = false,
    this.encryptionKey = false,
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

  /// A song is on its way to play on this device (outside a room, or while listening alone): nothing is heard yet,
  /// but something is happening.
  final bool loading;

  /// Songs are played with their picture on this device.
  final bool video;

  /// Tallest picture fetched, in pixels.
  final int videoHeight;

  /// How fast this device plays outside a room, 1 being normal. In a room it is always 1.
  final double playbackSpeed;

  /// Room name, when it has one.
  final String? name;

  /// The member who owns the room, when it has an owner.
  final String? ownerId;

  /// The look of the room's chat: a [ChatTheme] id, `default` for none. Null outside a room and when the server is too
  /// old to have one, in which case the look cannot be changed.
  final String? theme;
  final GuestControl guestControl;

  /// The room carries on with similar songs when its queue runs out. Null outside a room and when the server is too
  /// old to say, in which case nothing carries on.
  final bool? roomAutoplay;

  /// The room stops, for a few seconds at most, for a device that stalls. Null outside a room and when the server is too
  /// old to say, in which case the room never waits.
  final bool? roomWaitWeak;

  /// What is still to come is mixed, and stays mixed as songs are added: this device's own outside a room, the room's
  /// in one. Null in a room whose server is too old to say, where shuffle is only a one-time mix.
  final bool? shuffle;

  /// The room's chat is end-to-end encrypted: the server keeps and passes on sealed messages it cannot read.
  final bool encrypted;

  /// This device has the secret that opens the room's sealed chat.
  final bool encryptionKey;

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

  /// The songs members chose that come after the one playing: the queue as they made it.
  List<QueueEntry> get upNext => [
    for (final e in _after)
      if (!e.auto) e,
  ];

  /// The songs autoplay lined up behind them. Only a room has any: it keeps them apart from the members' songs.
  List<QueueEntry> get autoUpNext => [
    for (final e in _after)
      if (e.auto) e,
  ];

  List<QueueEntry> get _after =>
      myIndex + 1 < queue.length ? queue.sublist(myIndex + 1) : const [];

  /// The song is waiting in the queue: playing now or still to come. One that was played already is not. Its
  /// video and its audio release count as the same song.
  bool isQueued(Track track) {
    // Outside a room an idle queue has played through
    if (!inRoom && phase == 'idle') return false;
    return _waiting.any((e) => sameSong(e, track));
  }

  /// The songs waiting in the queue: the one playing and those still to come. What autoplay lined up does not count,
  /// since a member may pick it themselves, and the room then takes it off.
  Iterable<QueueEntry> get _waiting sync* {
    var first = true;
    for (final e in queue.skip(index)) {
      if (first || !e.auto) yield e;
      first = false;
    }
  }

  /// [tracks] without those that are waiting in the queue already, and without repeats. The same as asking [isQueued] of
  /// each, but the queue is looked through once: a folder of a thousand songs put on a queue of a thousand would otherwise
  /// compare a million pairs.
  List<T> fresh<T extends Track>(List<T> tracks) {
    if (!inRoom && phase == 'idle') return uniqueSongs(tracks);
    final ids = <String>{};
    final byKey = <String, List<QueueEntry>>{};
    for (final e in _waiting) {
      ids.add(e.videoId);
      byKey.putIfAbsent(songKey(e.title, e.artist), () => []).add(e);
    }
    return uniqueSongs(
      tracks.where(
        (t) =>
            !ids.contains(t.videoId) &&
            !(byKey[songKey(t.title, t.artist)]?.any((e) => sameSong(e, t)) ??
                false),
      ),
    );
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
    loading: json['loading'] as bool? ?? false,
    video: json['video'] as bool? ?? false,
    videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 720,
    playbackSpeed: (json['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
    name: json['name'] as String?,
    ownerId: json['ownerId'] as String?,
    theme: json['theme'] as String?,
    guestControl: GuestControl.parse(json['guestControl'] as String?),
    roomAutoplay: json['roomAutoplay'] as bool?,
    roomWaitWeak: json['roomWaitWeak'] as bool?,
    shuffle: json['shuffle'] as bool?,
    encrypted: json['encrypted'] as bool? ?? false,
    encryptionKey: json['encryptionKey'] as bool? ?? false,
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

/// Where a chat message of this device is: the room has it ([sent]), it is on its way, or it never got there.
enum ChatDelivery { sent, sending, failed }

/// A chat message of the room. Until the room confirms one of this device's own, [id] is 0 and [delivery] says how it goes.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.by,
    required this.name,
    required this.text,
    required this.at,
    this.cid,
    this.delivery = ChatDelivery.sent,
    this.reply,
    this.reactions = const {},
    this.locked = false,
    this.ct,
    this.pv,
    this.x,
  });

  /// The room's number for it, one more with every message.
  final int id;

  /// The member who wrote it.
  final String by;

  /// Their name when they wrote it, so it stays after they leave.
  final String name;
  final String text;

  /// When it was sent, in ms since the epoch.
  final int at;

  /// The id this device gave it when it wrote it; null for messages of the others.
  final String? cid;
  final ChatDelivery delivery;

  /// The message this one answers, as it was when the answer was written.
  final ChatQuote? reply;

  /// What members reacted with, by the id of each. A member has one reaction to a message.
  final Map<String, Reaction> reactions;

  /// A sealed message that this device cannot read: it has no secret for the room, or not the one it was sealed with.
  final bool locked;

  /// In a room with end-to-end encrypted chat, as the room sends it: the words sealed, and the start of them sealed apart
  /// for a notice. Only the web build gets them (the phones open them in their native side); [text] is then empty.
  final String? ct;
  final String? pv;

  /// What the message carries besides words (a song, pictures, a sticker): an object with a kind `k`; null for plain words.
  /// The words in [text] stand in for it where the kind is not known.
  final Map<String, dynamic>? x;

  /// The same message with its sealed words read.
  ChatMessage sealedAs({
    required String text,
    ChatQuote? reply,
    Map<String, dynamic>? x,
  }) => ChatMessage(
    id: id,
    by: by,
    name: name,
    text: text,
    at: at,
    cid: cid,
    delivery: delivery,
    reply: reply,
    reactions: reactions,
    x: x,
  );

  /// The same message as one that cannot be read.
  ChatMessage get asLocked => ChatMessage(
    id: id,
    by: by,
    name: name,
    text: '',
    at: at,
    cid: cid,
    delivery: delivery,
    reactions: reactions,
    locked: true,
  );

  ChatMessage withDelivery(ChatDelivery delivery) => ChatMessage(
    id: id,
    by: by,
    name: name,
    text: text,
    at: at,
    cid: cid,
    delivery: delivery,
    reply: reply,
    reactions: reactions,
    locked: locked,
    x: x,
  );

  /// The same message with [member]'s reaction to it set, or ([reaction] null) taken away.
  ChatMessage withReaction(String member, Reaction? reaction) => ChatMessage(
    id: id,
    by: by,
    name: name,
    text: text,
    at: at,
    cid: cid,
    delivery: delivery,
    reply: reply,
    reactions: {
      for (final e in reactions.entries)
        if (e.key != member) e.key: e.value,
      member: ?reaction,
    },
    locked: locked,
    x: x,
  );

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: (json['id'] as num).toInt(),
    by: json['by'] as String,
    name: json['name'] as String? ?? '',
    text: json['text'] as String,
    at: (json['at'] as num).toInt(),
    cid: json['cid'] as String?,
    reply: json['re'] == null
        ? null
        : ChatQuote.fromJson(json['re'] as Map<String, dynamic>),
    reactions: {
      for (final e in (json['rx'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: ?Reaction.parse(e.value as String?),
    },
    locked: json['locked'] as bool? ?? false,
    ct: json['ct'] as String?,
    pv: json['pv'] as String?,
    x: _extra(json['x']),
  );

  /// The extra of a message as the native side hands it (JSON text) or the web wire (an object); null when it is neither.
  static Map<String, dynamic>? _extra(Object? raw) {
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      return value is Map<String, dynamic> && value['k'] is String
          ? value
          : null;
    } on FormatException {
      return null;
    }
  }
}

/// A ticket to put one file in the room's bucket: its id [m], the path [url] of this server to put it at, and the [token]
/// that goes with it.
class MediaTicket {
  const MediaTicket({required this.m, required this.url, required this.token});

  final String m;
  final String url;
  final String token;

  factory MediaTicket.fromJson(Map<Object?, Object?> json) => MediaTicket(
    m: json['m'] as String,
    url: json['url'] as String,
    token: json['token'] as String,
  );
}

/// The room's answer to a request for tickets: one for each file in order, or the [error] it gave (`media_full`,
/// `media_limit`, `media_too_big`, `media_unavailable`, or `offline` when nobody answered).
class MediaTickets {
  const MediaTickets.granted(this.tickets) : error = null;
  const MediaTickets.refused(String this.error) : tickets = const [];

  final List<MediaTicket> tickets;
  final String? error;

  bool get granted => error == null;

  factory MediaTickets.fromMap(Map<Object?, Object?> map) {
    final error = map['error'] as String?;
    if (error != null) return MediaTickets.refused(error);
    return MediaTickets.granted([
      for (final t in map['tickets'] as List<Object?>? ?? const [])
        MediaTicket.fromJson(t as Map<Object?, Object?>),
    ]);
  }
}

/// What a reply shows of the message it answers.
class ChatQuote {
  const ChatQuote({
    required this.id,
    required this.by,
    required this.name,
    required this.text,
  });

  final int id;
  final String by;
  final String name;
  final String text;

  factory ChatQuote.fromJson(Map<String, dynamic> json) => ChatQuote(
    id: (json['id'] as num).toInt(),
    by: json['by'] as String,
    name: json['name'] as String? ?? '',
    text: json['text'] as String? ?? '',
  );
}

/// What a member has got of the chat: the last message that reached their device, and the last one they looked at.
class ChatReceipt {
  const ChatReceipt({this.delivered = 0, this.read = 0});

  final int delivered;
  final int read;

  factory ChatReceipt.fromJson(Map<String, dynamic> json) => ChatReceipt(
    delivered: (json['d'] as num?)?.toInt() ?? 0,
    read: (json['r'] as num?)?.toInt() ?? 0,
  );
}

enum ChatStage { sending, failed, sent, delivered, seen }

/// How far a message of this device has come: on its way, lost, in the room, in other devices, or looked at.
class ChatProgress {
  const ChatProgress.sending() : stage = ChatStage.sending, seenBy = const [];
  const ChatProgress.failed() : stage = ChatStage.failed, seenBy = const [];
  const ChatProgress.sent() : stage = ChatStage.sent, seenBy = const [];
  const ChatProgress.delivered() : stage = ChatStage.delivered, seenBy = const [];
  const ChatProgress.seen(this.seenBy) : stage = ChatStage.seen;

  final ChatStage stage;

  /// The names of those who looked at it, when [stage] is [ChatStage.seen].
  final List<String> seenBy;
}

/// What a member can send the room: one emoji. The first ones this app had go on the wire by [name], so that apps
/// which know only those still show them; any other goes as the emoji itself.
class Reaction {
  const Reaction(this.emoji, [this.name]);

  final String emoji;
  final String? name;

  /// How it goes to the room.
  String get wire => name ?? emoji;

  static const heart = Reaction('❤️', 'heart');
  static const love = Reaction('😍', 'love');
  static const kiss = Reaction('😘', 'kiss');
  static const hug = Reaction('🤗', 'hug');
  static const blush = Reaction('😊', 'blush');
  static const cool = Reaction('😎', 'cool');
  static const wink = Reaction('😉', 'wink');
  static const pleading = Reaction('🥺', 'pleading');
  static const laugh = Reaction('😂', 'laugh');
  static const rofl = Reaction('🤣', 'rofl');
  static const grin = Reaction('😁', 'grin');
  static const wow = Reaction('😮', 'wow');
  static const mindblown = Reaction('🤯', 'mindblown');
  static const think = Reaction('🤔', 'think');
  static const eyes = Reaction('👀', 'eyes');
  static const sad = Reaction('😢', 'sad');
  static const cry = Reaction('😭', 'cry');
  static const skull = Reaction('💀', 'skull');
  static const sleepy = Reaction('😴', 'sleepy');
  static const fire = Reaction('🔥', 'fire');
  static const clap = Reaction('👏', 'clap');
  static const raise = Reaction('🙌', 'raise');
  static const party = Reaction('🥳', 'party');
  static const hundred = Reaction('💯', 'hundred');
  static const sparkles = Reaction('✨', 'sparkles');
  static const rocket = Reaction('🚀', 'rocket');
  static const muscle = Reaction('💪', 'muscle');
  static const thumbsup = Reaction('👍', 'thumbsup');
  static const thumbsdown = Reaction('👎', 'thumbsdown');
  static const ok = Reaction('👌', 'ok');
  static const pray = Reaction('🙏', 'pray');
  static const music = Reaction('🎶', 'music');
  static const dance = Reaction('💃', 'dance');
  static const headphones = Reaction('🎧', 'headphones');
  static const mic = Reaction('🎤', 'mic');
  static const guitar = Reaction('🎸', 'guitar');
  static const drum = Reaction('🥁', 'drum');
  static const speaker = Reaction('🔊', 'speaker');
  static const replay = Reaction('🔁', 'replay');

  /// The ones that go by name.
  static const named = [
    heart,
    love,
    kiss,
    hug,
    blush,
    cool,
    wink,
    pleading,
    laugh,
    rofl,
    grin,
    wow,
    mindblown,
    think,
    eyes,
    sad,
    cry,
    skull,
    sleepy,
    fire,
    clap,
    raise,
    party,
    hundred,
    sparkles,
    rocket,
    muscle,
    thumbsup,
    thumbsdown,
    ok,
    pray,
    music,
    dance,
    headphones,
    mic,
    guitar,
    drum,
    speaker,
    replay,
  ];

  /// The ones always in reach, one tap each; the rest are a tap further.
  static const quick = [heart, fire, laugh, wow, sad, clap];

  /// Most UTF-16 units one emoji takes (a family or a flag of a region joins up to a dozen), as the room accepts.
  static const maxEmojiUnits = 32;

  static const _emojiPattern =
      r'^(?=.*[\p{Extended_Pictographic}\p{Regional_Indicator}\u20E3])'
      r'(?:\p{Extended_Pictographic}|\p{Regional_Indicator}|\p{Emoji_Modifier}|[\uFE0F\u200D\u20E3#*0-9]|[\u{E0020}-\u{E007F}])+$';

  static final _emoji = RegExp(_emojiPattern, unicode: true);

  /// The reaction for an emoji picked: the one that goes by name if it has one.
  static Reaction of(String emoji) {
    for (final reaction in named) {
      if (reaction.emoji == emoji) return reaction;
    }
    return Reaction(emoji);
  }

  /// The reaction a name or an emoji from the room stands for; null for anything else.
  static Reaction? parse(String? wire) {
    if (wire == null) return null;
    for (final reaction in named) {
      if (reaction.name == wire) return reaction;
    }
    return wire.length <= maxEmojiUnits && _emoji.hasMatch(wire)
        ? Reaction(wire)
        : null;
  }

  @override
  bool operator ==(Object other) => other is Reaction && other.emoji == emoji;

  @override
  int get hashCode => emoji.hashCode;
}

/// The local player, sampled about once a second and extrapolated in between.
class PlayerPosition {
  const PlayerPosition({
    this.playing = false,
    this.buffering = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.driftMs,
    this.weak = false,
    this.lagMs = 0,
    this.speed = 1.0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.noPicture = false,
    this.heldBack = false,
  });

  final bool playing;
  final bool buffering;
  final int positionMs;
  final int durationMs;

  /// How far this device is from the room's position, or null when not playing in sync.
  final int? driftMs;

  /// The network is too weak to keep up with the room, so this device plays [lagMs] behind it, and says so.
  final bool weak;
  final int lagMs;
  final double speed;

  /// Size of the picture being played, or 0 until there is one.
  final int videoWidth;
  final int videoHeight;

  /// The picture is wanted but this song plays without one: none could be had.
  final bool noPicture;

  /// This device follows a room that plays on, but its own player is paused: a headset, a call or another app did it
  /// here. The room's phase says playing, this device is silent.
  final bool heldBack;

  factory PlayerPosition.fromJson(Map<String, dynamic> json) => PlayerPosition(
    playing: json['playing'] as bool? ?? false,
    buffering: json['buffering'] as bool? ?? false,
    positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    driftMs: (json['driftMs'] as num?)?.toInt(),
    weak: json['weak'] as bool? ?? false,
    lagMs: (json['lagMs'] as num?)?.toInt() ?? 0,
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
    videoWidth: (json['videoWidth'] as num?)?.toInt() ?? 0,
    videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 0,
    noPicture: json['noPicture'] as bool? ?? false,
    heldBack: json['heldBack'] as bool? ?? false,
  );
}

/// Something the server told this device that the user should see.
class ServerError {
  const ServerError(this.code, this.message);

  final String code;
  final String message;
}

/// How much sound a song is fetched in, from the least data to the most YouTube offers. The index is what the native
/// side keeps and what both platforms agree on.
enum AudioQuality {
  low,
  normal,
  high,
  max;

  /// The step for a number from the native side; anything unknown is the best, which is what the app did before
  /// there was a choice.
  static AudioQuality of(int? level) =>
      level != null && level >= 0 && level < values.length
      ? values[level]
      : max;
}

class Profile {
  const Profile({
    this.name,
    this.device = '',
    this.trimMs = 0,
    this.server = '',
    this.autoplay = true,
    this.shareTaste = true,
    this.configured = true,
    this.hasKey = true,
    this.audioQuality = AudioQuality.max,
    this.normalizeVolume = true,
    this.libraryLost = false,
  });

  /// Name used in the last room, to prefill the field asking for it.
  final String? name;
  final String device;
  final int trimMs;

  /// Address of the room server, where invitation links live.
  final String server;

  /// The music carries on with similar songs when the queue runs out.
  final bool autoplay;

  /// A room's autoplay may be given a few songs this person loves, to start from.
  final bool shareTaste;

  /// How much sound a song that is not kept yet is fetched in.
  final AudioQuality audioQuality;

  /// Loud songs are turned down to the level of the others. A browser has nothing to say in it: YouTube's player does it.
  final bool normalizeVolume;

  /// The address of the room server is known. On Android it is built into the app; on iOS the person enters it.
  final bool configured;

  /// The key the server asks for is known.
  final bool hasKey;

  /// The library file could not be opened (iPhone) and an empty one stands in: what is changed in it is lost when the
  /// app closes, and a backup restored into it with it.
  final bool libraryLost;

  Profile withAutoplay(bool value) => Profile(
    name: name,
    device: device,
    trimMs: trimMs,
    server: server,
    autoplay: value,
    shareTaste: shareTaste,
    configured: configured,
    hasKey: hasKey,
    audioQuality: audioQuality,
    normalizeVolume: normalizeVolume,
    libraryLost: libraryLost,
  );

  Profile withShareTaste(bool value) => Profile(
    name: name,
    device: device,
    trimMs: trimMs,
    server: server,
    autoplay: autoplay,
    shareTaste: value,
    configured: configured,
    hasKey: hasKey,
    audioQuality: audioQuality,
    normalizeVolume: normalizeVolume,
    libraryLost: libraryLost,
  );

  Profile withAudioQuality(AudioQuality value) => Profile(
    name: name,
    device: device,
    trimMs: trimMs,
    server: server,
    autoplay: autoplay,
    shareTaste: shareTaste,
    configured: configured,
    hasKey: hasKey,
    audioQuality: value,
    normalizeVolume: normalizeVolume,
    libraryLost: libraryLost,
  );

  Profile withNormalizeVolume(bool value) => Profile(
    name: name,
    device: device,
    trimMs: trimMs,
    server: server,
    autoplay: autoplay,
    shareTaste: shareTaste,
    configured: configured,
    hasKey: hasKey,
    audioQuality: audioQuality,
    normalizeVolume: value,
    libraryLost: libraryLost,
  );

  factory Profile.fromMap(Map<Object?, Object?> map) => Profile(
    name: map['name'] as String?,
    device: map['device'] as String? ?? '',
    trimMs: (map['trimMs'] as num?)?.toInt() ?? 0,
    server: map['server'] as String? ?? '',
    autoplay: map['autoplay'] as bool? ?? true,
    shareTaste: map['shareTaste'] as bool? ?? true,
    configured: map['configured'] as bool? ?? true,
    hasKey: map['key'] as bool? ?? true,
    audioQuality: AudioQuality.of((map['audioQuality'] as num?)?.toInt()),
    normalizeVolume: map['normalizeVolume'] as bool? ?? true,
    libraryLost: map['libraryLost'] as bool? ?? false,
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

/// What asking the room server three things told: [reachable] is whether `/health` answered, [protocol] is the version
/// of the room protocol it says it speaks, and [keyAccepted] is whether it took the key (null when it could not be asked).
class ServerCheck {
  const ServerCheck({
    this.reachable = false,
    this.protocol,
    this.keyAccepted,
  });

  final bool reachable;
  final int? protocol;
  final bool? keyAccepted;

  factory ServerCheck.fromMap(Map<Object?, Object?> map) => ServerCheck(
    reachable: map['reachable'] as bool? ?? false,
    protocol: (map['protocol'] as num?)?.toInt(),
    keyAccepted: map['keyAccepted'] as bool?,
  );
}

/// Where the sound goes: [kind] is `speaker`, `headphones`, `bluetooth`, `airplay`, `car` or `other`, and [name] is
/// what the device calls itself (empty for the phone's own speaker).
class AudioOutput {
  const AudioOutput({this.kind = 'speaker', this.name = ''});

  final String kind;
  final String name;

  factory AudioOutput.fromJson(Map<String, dynamic> json) => AudioOutput(
    kind: json['kind'] as String? ?? 'speaker',
    name: json['name'] as String? ?? '',
  );
}

/// How many songs, playlists and listens a backup file holds, or how many of them a restore added. [local] is how many
/// songs from files on this phone were left out of a backup: such a file is not on another phone.
class BackupCounts {
  const BackupCounts({
    this.liked = 0,
    this.playlists = 0,
    this.listens = 0,
    this.local = 0,
  });

  final int liked;
  final int playlists;
  final int listens;
  final int local;

  bool get isEmpty => liked == 0 && playlists == 0 && listens == 0;

  factory BackupCounts.fromMap(Map<Object?, Object?> map) => BackupCounts(
    liked: (map['liked'] as num?)?.toInt() ?? 0,
    playlists: (map['playlists'] as num?)?.toInt() ?? 0,
    listens: (map['listens'] as num?)?.toInt() ?? 0,
    local: (map['local'] as num?)?.toInt() ?? 0,
  );
}

/// Whether the app may read the music on this phone: [granted]; [ask] (not asked yet, or not refused for good); or
/// [blocked] (refused for good: only the phone's settings can change it).
enum LocalAccess {
  granted,
  ask,
  blocked;

  static LocalAccess parse(String? name) =>
      LocalAccess.values.asNameMap()[name] ?? LocalAccess.ask;
}

/// Where the list of the music on this phone stands: [enabled] is the person's switch, [count] the files that are there,
/// [missing] the songs whose file is gone.
class LocalStatus {
  const LocalStatus({
    this.enabled = true,
    this.access = LocalAccess.ask,
    this.count = 0,
    this.missing = const {},
  });

  final bool enabled;
  final LocalAccess access;
  final int count;
  final Set<String> missing;

  @override
  bool operator ==(Object other) =>
      other is LocalStatus &&
      other.enabled == enabled &&
      other.access == access &&
      other.count == count &&
      other.missing.length == missing.length &&
      other.missing.containsAll(missing);

  @override
  int get hashCode => Object.hash(enabled, access, count, missing.length);

  factory LocalStatus.fromMap(Map<Object?, Object?> map) => LocalStatus(
    enabled: map['enabled'] as bool? ?? true,
    access: LocalAccess.parse(map['access'] as String?),
    count: (map['count'] as num?)?.toInt() ?? 0,
    missing: {
      for (final id in map['missing'] as List<Object?>? ?? const []) '$id',
    },
  );
}

/// A music file on this phone: its song, and what the file adds to it.
class LocalSong {
  const LocalSong({
    required this.track,
    this.album = '',
    this.mime = '',
    this.size = 0,
    this.addedAt = 0,
    this.missing = false,
  });

  final Track track;
  final String album;
  final String mime;
  final int size;

  /// Milliseconds since the epoch.
  final int addedAt;

  /// The file was there once and is not now; its song is still in the playlists and likes that point to it.
  final bool missing;

  @override
  bool operator ==(Object other) =>
      other is LocalSong &&
      other.track.videoId == track.videoId &&
      other.track.title == track.title &&
      other.track.artist == track.artist &&
      other.track.thumb == track.thumb &&
      other.track.durMs == track.durMs &&
      other.album == album &&
      other.mime == mime &&
      other.size == size &&
      other.addedAt == addedAt &&
      other.missing == missing;

  @override
  int get hashCode =>
      Object.hash(track.videoId, track.title, track.artist, album, addedAt, missing);

  factory LocalSong.fromMap(Map<Object?, Object?> map) => LocalSong(
    track: Track.fromMap(map),
    album: map['album'] as String? ?? '',
    mime: map['mime'] as String? ?? '',
    size: (map['size'] as num?)?.toInt() ?? 0,
    addedAt: (map['addedAt'] as num?)?.toInt() ?? 0,
    missing: map['missing'] as bool? ?? false,
  );
}

/// What a scan of the music on this phone found: how many files are there, and how many cannot be played here.
class LocalScan {
  const LocalScan({this.total = 0, this.unsupported = 0});

  final int total;
  final int unsupported;

  factory LocalScan.fromMap(Map<Object?, Object?> map) => LocalScan(
    total: (map['total'] as num?)?.toInt() ?? 0,
    unsupported: (map['unsupported'] as num?)?.toInt() ?? 0,
  );
}

/// Where a song that plays came from, kept beside every listen and skip so the suggestions can be judged by their
/// source. Dart counterpart of `ListenSource.kt` and `ListenSource.swift`.
abstract final class ListenSource {
  /// Picked on purpose: a search, the library, a playlist. Also what an old row without a source is taken for.
  static const chosen = 'chosen';

  /// Added by autoplay or by a radio, in the personal queue or in a room.
  static const auto = 'auto';

  /// Started from a shelf of the home page (Quick picks, a mix, Discover...).
  static const shelf = 'shelf';

  /// In a room, a song another member put on the queue.
  static const roomOther = 'room_other';

  /// What a song somebody else picked says about this person's taste, next to one they picked themselves (1).
  static const otherWeight = 0.5;

  static double weight(String? source) => source == roomOther ? otherWeight : 1.0;
}

/// How much an artist is loved, as the native side works it out: [key] is the artist in plain letters (see
/// [mainArtist]), [label] the name as it is written.
class ArtistRank {
  const ArtistRank({required this.key, required this.label, required this.score});

  final String key;
  final String label;
  final double score;

  @override
  bool operator ==(Object other) => other is ArtistRank && other.key == key && other.label == label && other.score == score;

  @override
  int get hashCode => Object.hash(key, label, score);
}

/// What the person told the taste (see [TasteMarks]): [kind], what it is about ([key]: an artist in plain letters or a
/// video id), how to show it ([label]) and when.
class TasteMark {
  const TasteMark({required this.kind, required this.key, required this.label, this.at = 0});

  final String kind;
  final String key;
  final String label;
  final int at;

  factory TasteMark.fromMap(Map<Object?, Object?> map) => TasteMark(
    kind: map['kind'] as String? ?? '',
    key: map['key'] as String? ?? '',
    label: map['label'] as String? ?? '',
    at: (map['at'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) => other is TasteMark && other.kind == kind && other.key == key && other.label == label && other.at == at;

  @override
  int get hashCode => Object.hash(kind, key, label, at);
}

/// The kinds of [TasteMark], as the native side knows them.
abstract final class TasteMarks {
  /// An artist to be suggested less: not a seed, not known, nothing offered to a room; their songs still play.
  static const quietArtist = 'quiet_artist';

  /// A song that is not to count: whatever happened to it is left out of the taste.
  static const quietSong = 'quiet_song';

  /// A song a new person chose an artist by (key: its video id; label: the song as JSON): counts as heard when chosen.
  static const starter = 'starter';

  /// The label of a [starter] mark for [track].
  static String starterLabel(Track track) =>
      jsonEncode({'videoId': track.videoId, 'title': track.title, 'artist': track.artist, 'thumb': track.thumb, 'durMs': track.durMs});

  /// The song a [starter] mark stands for; null when its [label] is not a song.
  static Track? starterTrack(String label) {
    try {
      final o = jsonDecode(label) as Map<String, dynamic>;
      return Track(
        videoId: o['videoId'] as String,
        title: o['title'] as String? ?? '',
        artist: o['artist'] as String? ?? '',
        thumb: o['thumb'] as String?,
        durMs: (o['durMs'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return null;
    }
  }
}

/// What the listening says about the person, as the native side works it out. Every list is ready to draw.
class TasteProfile {
  const TasteProfile({this.artists = const [], this.songs = const {}, this.marks = const [], this.stats = const []});

  /// The artists with the highest score, the highest first. A score below nothing is an artist left again and again.
  final List<ArtistRank> artists;

  /// How much each song is loved, by video id; below nothing for a song left more than it was heard.
  final Map<String, double> songs;

  /// What the person told the taste, the latest first.
  final List<TasteMark> marks;

  /// How the songs of each source fared in the last 30 days.
  final List<SourceStats> stats;

  /// The marks of one [kind].
  Iterable<TasteMark> marksOf(String kind) => marks.where((m) => m.kind == kind);

  factory TasteProfile.fromMap(Map<Object?, Object?> map) => TasteProfile(
    artists: [
      for (final e in map['artists'] as List<Object?>? ?? const [])
        ArtistRank(
          key: (e as Map<Object?, Object?>)['key'] as String? ?? '',
          label: e['label'] as String? ?? '',
          score: (e['score'] as num?)?.toDouble() ?? 0,
        ),
    ],
    songs: {
      for (final e in (map['songs'] as Map<Object?, Object?>? ?? const {}).entries)
        e.key as String: (e.value as num).toDouble(),
    },
    marks: [
      for (final e in map['marks'] as List<Object?>? ?? const []) TasteMark.fromMap(e as Map<Object?, Object?>),
    ],
    stats: [
      for (final e in map['stats'] as List<Object?>? ?? const []) SourceStats.fromMap(e as Map<Object?, Object?>),
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is TasteProfile &&
      listEquals(artists, other.artists) &&
      mapEquals(songs, other.songs) &&
      listEquals(marks, other.marks) &&
      listEquals(stats, other.stats);

  @override
  int get hashCode => Object.hash(Object.hashAll(artists), Object.hashAll(songs.entries.map((e) => Object.hash(e.key, e.value))), Object.hashAll(marks), Object.hashAll(stats));
}

/// How the songs from one [source] fared lately: heard for long enough, and left after a few seconds.
class SourceStats {
  const SourceStats({required this.source, required this.heard, required this.skipped});

  final String source;
  final int heard;
  final int skipped;

  @override
  bool operator ==(Object other) =>
      other is SourceStats && other.source == source && other.heard == heard && other.skipped == skipped;

  @override
  int get hashCode => Object.hash(source, heard, skipped);

  factory SourceStats.fromMap(Map<Object?, Object?> map) => SourceStats(
    source: map['source'] as String? ?? ListenSource.chosen,
    heard: (map['heard'] as num?)?.toInt() ?? 0,
    skipped: (map['skipped'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toMap() => {'source': source, 'heard': heard, 'skipped': skipped};

  /// The share of the songs that were left, 0 to 1; null when there were none.
  double? get skipRate => heard + skipped == 0 ? null : skipped / (heard + skipped);

  int get total => heard + skipped;
}
