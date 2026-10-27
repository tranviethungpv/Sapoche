import 'dart:convert';

import '../models.dart';

// Wire protocol with the room server. Mirrors Protocol.kt, Wire.swift, server/src/protocol.ts and docs/PROTOCOL.md.
// The picture of a member is `av` in the member list and `avatar` when it is asked for; the other types are the app's own models.

/// Room state as the server broadcasts it. [phase] is one of idle, preparing, playing, paused.
class RoomState {
  const RoomState({
    required this.queue,
    required this.index,
    required this.phase,
    required this.startedAt,
    required this.positionMs,
    required this.epoch,
    this.repeat = 'off',
    this.name,
    this.ownerId,
    this.guestControl = 'all',
    this.autoplay,
    this.shuffle,
  });

  final List<QueueEntry> queue;
  final int index;
  final String phase;

  /// Server time at which position 0 of the current item is played. Valid while playing.
  final int startedAt;

  /// Position in the current item; authoritative while paused or preparing.
  final int positionMs;
  final int epoch;
  final String repeat;
  final String? name;
  final String? ownerId;
  final String guestControl;

  /// Null when the server is older than protocol 9 (autoplay) or 11 (shuffle).
  final bool? autoplay;
  final bool? shuffle;

  QueueEntry? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  RoomState copyWith({
    int? index,
    String? phase,
    int? startedAt,
    int? positionMs,
    int? epoch,
  }) => RoomState(
    queue: queue,
    index: index ?? this.index,
    phase: phase ?? this.phase,
    startedAt: startedAt ?? this.startedAt,
    positionMs: positionMs ?? this.positionMs,
    epoch: epoch ?? this.epoch,
    repeat: repeat,
    name: name,
    ownerId: ownerId,
    guestControl: guestControl,
    autoplay: autoplay,
    shuffle: shuffle,
  );

  factory RoomState.fromJson(Map<String, dynamic> json) => RoomState(
    queue: [
      for (final e in json['queue'] as List<dynamic>)
        QueueEntry.fromJson(e as Map<String, dynamic>),
    ],
    index: (json['index'] as num).toInt(),
    phase: json['phase'] as String,
    startedAt: (json['startedAt'] as num).toInt(),
    positionMs: (json['positionMs'] as num).toInt(),
    epoch: (json['epoch'] as num).toInt(),
    repeat: json['repeat'] as String? ?? 'off',
    name: json['name'] as String?,
    ownerId: json['ownerId'] as String?,
    guestControl: json['guestControl'] as String? ?? 'all',
    autoplay: json['autoplay'] as bool?,
    shuffle: json['shuffle'] as bool?,
  );
}

sealed class ServerMessage {
  const ServerMessage();
}

class StateMessage extends ServerMessage {
  const StateMessage({
    required this.serverNow,
    required this.you,
    required this.state,
    required this.members,
    required this.protocol,
  });

  final int serverNow;
  final String you;
  final RoomState state;
  final List<Member> members;

  /// Protocol version of the server; 0 when an older server does not say.
  final int protocol;
}

class MembersMessage extends ServerMessage {
  const MembersMessage(this.members);
  final List<Member> members;
}

/// [by] is the public id of whoever asked for it; null when the room moved on by itself.
class PrepareMessage extends ServerMessage {
  const PrepareMessage({
    required this.epoch,
    required this.index,
    required this.item,
    required this.seekToMs,
    this.by,
  });
  final int epoch;
  final int index;
  final QueueEntry item;
  final int seekToMs;
  final String? by;
}

/// Play so that position [positionMs] is heard at server time [startAt].
class StartMessage extends ServerMessage {
  const StartMessage({
    required this.epoch,
    required this.startAt,
    required this.positionMs,
    this.by,
  });
  final int epoch;
  final int startAt;
  final int positionMs;
  final String? by;
}

class PauseMessage extends ServerMessage {
  const PauseMessage({required this.epoch, required this.positionMs, this.by});
  final int epoch;
  final int positionMs;
  final String? by;
}

/// The room moved on to the item at [index]; position 0 of it was heard at server time [startedAt].
class AdvanceMessage extends ServerMessage {
  const AdvanceMessage({
    required this.epoch,
    required this.index,
    required this.startedAt,
  });
  final int epoch;
  final int index;
  final int startedAt;
}

class PongMessage extends ServerMessage {
  const PongMessage({required this.c0, required this.s1});
  final int c0;
  final int s1;
}

/// The room's queue ran out and this device is asked to find songs like [videoId].
class AutoplayFillMessage extends ServerMessage {
  const AutoplayFillMessage({
    required this.epoch,
    required this.videoId,
    required this.title,
  });
  final int epoch;
  final String videoId;
  final String title;
}

class AvatarMessage extends ServerMessage {
  const AvatarMessage({required this.id, this.av, this.data});
  final String id;
  final String? av;
  final String? data;
}

class ChatMessageReceived extends ServerMessage {
  const ChatMessageReceived(this.message);
  final ChatMessage message;
}

class ChatHistoryMessage extends ServerMessage {
  const ChatHistoryMessage(this.messages, this.receipts);
  final List<ChatMessage> messages;
  final Map<String, ChatReceipt> receipts;
}

/// A message changed, as somebody reacted to it: its new version.
class ChatUpdateMessage extends ServerMessage {
  const ChatUpdateMessage(this.message);
  final ChatMessage message;
}

class ChatReceiptsMessage extends ServerMessage {
  const ChatReceiptsMessage(this.receipts);
  final Map<String, ChatReceipt> receipts;
}

class ReactMessage extends ServerMessage {
  const ReactMessage({required this.by, required this.e, this.n = 1});
  final String by;
  final String e;
  final int n;
}

class ErrorMessage extends ServerMessage {
  const ErrorMessage({required this.code, required this.message});
  final String code;
  final String message;
}

Map<String, ChatReceipt> _receipts(Object? raw) => {
  for (final e in (raw as Map<String, dynamic>? ?? const {}).entries)
    e.key: ChatReceipt.fromJson(e.value as Map<String, dynamic>),
};

List<Member> _members(Object? raw) => [
  for (final e in raw as List<dynamic>) Member.fromJson(e as Map<String, dynamic>),
];

/// Returns null for anything that is not a well-formed message this app understands.
ServerMessage? parseServerMessage(String text) {
  try {
    final obj = jsonDecode(text) as Map<String, dynamic>;
    int n(String key) => (obj[key] as num).toInt();
    return switch (obj['t']) {
      'state' => StateMessage(
        serverNow: n('serverNow'),
        you: obj['you'] as String,
        state: RoomState.fromJson(obj['state'] as Map<String, dynamic>),
        members: _members(obj['members']),
        protocol: (obj['protocol'] as num?)?.toInt() ?? 0,
      ),
      'members' => MembersMessage(_members(obj['members'])),
      'prepare' => PrepareMessage(
        epoch: n('epoch'),
        index: n('index'),
        item: QueueEntry.fromJson(obj['item'] as Map<String, dynamic>),
        seekToMs: n('seekToMs'),
        by: obj['by'] as String?,
      ),
      'start' => StartMessage(
        epoch: n('epoch'),
        startAt: n('startAt'),
        positionMs: n('positionMs'),
        by: obj['by'] as String?,
      ),
      'pause' => PauseMessage(
        epoch: n('epoch'),
        positionMs: n('positionMs'),
        by: obj['by'] as String?,
      ),
      'advance' => AdvanceMessage(
        epoch: n('epoch'),
        index: n('index'),
        startedAt: n('startedAt'),
      ),
      'pong' => PongMessage(c0: n('c0'), s1: n('s1')),
      'autoplay.fill' => AutoplayFillMessage(
        epoch: n('epoch'),
        videoId: obj['videoId'] as String,
        title: obj['title'] as String,
      ),
      'avatar' => AvatarMessage(
        id: obj['id'] as String,
        av: obj['av'] as String?,
        data: obj['data'] as String?,
      ),
      'chat' => ChatMessageReceived(
        ChatMessage.fromJson(obj['msg'] as Map<String, dynamic>),
      ),
      'chat.history' => ChatHistoryMessage([
        for (final e in obj['msgs'] as List<dynamic>)
          ChatMessage.fromJson(e as Map<String, dynamic>),
      ], _receipts(obj['receipts'])),
      'chat.update' => ChatUpdateMessage(
        ChatMessage.fromJson(obj['msg'] as Map<String, dynamic>),
      ),
      'chat.receipts' => ChatReceiptsMessage(_receipts(obj['receipts'])),
      'react' => ReactMessage(
        by: obj['by'] as String,
        e: obj['e'] as String,
        n: (obj['n'] as num?)?.toInt() ?? 1,
      ),
      'error' => ErrorMessage(
        code: obj['code'] as String,
        message: obj['message'] as String,
      ),
      _ => null,
    };
  } on Object {
    // A message that is not what the protocol says is skipped, like on the other platforms
    return null;
  }
}

/// A song to put on the queue; the server adds the item id and who added it.
class TrackRef {
  const TrackRef(this.videoId, this.title, this.artist, this.thumb, this.durMs);

  TrackRef.of(Track t) : this(t.videoId, t.title, t.artist, t.thumb, t.durMs);

  final String videoId;
  final String title;
  final String artist;
  final String? thumb;
  final int durMs;

  Map<String, Object?> toJson() => {
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'thumb': ?thumb,
    'durMs': durMs,
  };
}

/// Client to server messages, as the JSON text that goes on the wire.
abstract final class Wire {
  static String _msg(String t, [Map<String, Object?> body = const {}]) =>
      jsonEncode({'t': t, ...body});

  /// [create] says what the device expects: true for a code it just made, false for one it was given, so that a
  /// mistyped code is refused instead of opening an empty room. Null leaves it out.
  static String join(String clientId, String name, {bool? create}) =>
      _msg('join', {'clientId': clientId, 'name': name, 'create': ?create});

  static String bye() => _msg('bye');
  static String kick(String id) => _msg('kick', {'id': id});
  static String roomName(String name) => _msg('room.name', {'name': name});
  static String roomSettings(String guestControl) =>
      _msg('room.settings', {'guestControl': guestControl});

  /// [rttMs] is the best round trip this device has measured.
  static String ping(int c0, double? rttMs) =>
      _msg('ping', {'c0': c0, 'rtt': ?rttMs?.toInt()});

  static String avatarSet(String? data) => _msg('avatar.set', {'data': data});
  static String avatarGet(String id) => _msg('avatar.get', {'id': id});

  /// Asks to be told of the chat of [room] while away, at the browser with push subscription [sub]; see push.set in
  /// docs/PROTOCOL.md. [until] is server time in milliseconds.
  static String pushSet(Map<String, Object?> sub, String room, {int? until, bool preview = true, String? lang}) =>
      _msg('push.set', {'sub': sub, 'room': room, 'until': ?until, if (!preview) 'preview': false, 'lang': ?lang});
  static String pushClear() => _msg('push.clear');

  static String chat(String text, String cid, {int? reply}) =>
      _msg('chat', {'text': text, 'cid': cid, 'reply': ?reply});
  static String chatReact(int id, String? e) =>
      _msg('chat.react', {'id': id, 'e': e});
  static String chatReceipt({int? delivered, int? read}) =>
      _msg('chat.receipt', {'delivered': ?delivered, 'read': ?read});
  static String react(String e, int n) => _msg('react', {'e': e, 'n': n});

  static String queueAdd(TrackRef t, {bool playNext = false}) =>
      _msg('queue.add', {...t.toJson(), if (playNext) 'next': true});
  static String queueAddMany(
    List<TrackRef> tracks, {
    bool playNext = false,
    bool auto = false,
  }) => _msg('queue.addMany', {
    'tracks': [for (final t in tracks) t.toJson()],
    if (playNext) 'next': true,
    if (auto) 'auto': true,
  });

  static String repeat(String mode) => _msg('repeat', {'mode': mode});
  static String autoplay(bool on) => _msg('autoplay', {'on': on});
  static String shuffle(bool on) => _msg('shuffle', {'on': on});
  static String queueRemove(String id) => _msg('queue.remove', {'id': id});
  static String queueSwap(String id, TrackRef t) =>
      _msg('queue.swap', {'id': id, 'track': t.toJson()});
  static String queueClear() => _msg('queue.clear');
  static String queueShuffle() => _msg('queue.shuffle');
  static String queueMove(String id, int toIndex) =>
      _msg('queue.move', {'id': id, 'toIndex': toIndex});
  static String jump(String id) => _msg('jump', {'id': id});
  static String play() => _msg('play');
  static String pause() => _msg('pause');
  static String seek(int positionMs) => _msg('seek', {'positionMs': positionMs});

  /// [from] is the queue item the button was pressed on; the room ignores the press once it has left that item.
  static String next({String? from}) => _msg('next', {'from': ?from});
  static String prev({String? from}) => _msg('prev', {'from': ?from});
  static String solo(bool on) => _msg('solo', {'on': on});
  static String resync() => _msg('resync');
  static String ready(int epoch) => _msg('ready', {'epoch': epoch});
  static String resolveFailed(int epoch, String? reason) => _msg(
    'resolveFailed',
    {
      'epoch': epoch,
      'reason': ?(reason != null && reason.length > 200
          ? reason.substring(0, 200)
          : reason),
    },
  );
  static String ended(int epoch) => _msg('ended', {'epoch': epoch});
  static String advanced(int epoch, String itemId, int startedAt) => _msg(
    'advanced',
    {'epoch': epoch, 'itemId': itemId, 'startedAt': startedAt},
  );
}
