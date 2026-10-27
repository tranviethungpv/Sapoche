import 'dart:async';

import '../models.dart';
import 'clocks.dart';
import 'job.dart';
import 'room_socket.dart';
import 'wire.dart';

/// [refused]: the server turned this device away for good (room full, no such room, removed by the owner).
enum Connection { connecting, connected, reconnecting, closed, unauthorized, refused }

/// WebSocket connection to one room. Joins on every (re)connect, keeps the clock offset fresh with pings, and
/// reconnects with exponential backoff when the connection drops. Mirrors RoomClient.kt.
class RoomClient {
  RoomClient({
    required Uri baseUrl,
    required String roomCode,
    required this.clientId,
    required this.name,
    required this.clock,
    required this.nowMs,
    required this.probeAuth,
    String key = '',
    bool? create,
    this.log = _ignore,
    SocketOpener? opener,
    this.pingEvery = const Duration(seconds: 30),
    this.pongDeadline = const Duration(seconds: 45),
  }) : _createOnJoin = create,
       _opener = opener ?? defaultSocketOpener,
       _url = baseUrl.replace(
         scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
         path: '${baseUrl.path.replaceAll(RegExp(r'/+$'), '')}/room/${roomCode.toUpperCase()}',
         // A browser cannot set headers on a WebSocket, so the key goes in the address
         queryParameters: key.isEmpty ? null : {'key': key},
       );

  final String clientId;
  final ClockSync clock;

  /// Monotonic local clock in ms; must be the clock the session uses.
  final NowMs nowMs;
  final void Function(String line) log;

  /// A browser says nothing of why a connection failed, so after one that never opened this asks the server over plain
  /// HTTP: the status it answers with, or null when it cannot be reached.
  final Future<int?> Function() probeAuth;
  final Duration pingEvery;
  final Duration pongDeadline;

  static void _ignore(String _) {}

  final Uri _url;
  final SocketOpener _opener;

  void Function(ServerMessage message) onMessage = (_) {};

  /// Called after each successful (re)connect, once the join message was sent.
  void Function() onConnected = () {};

  /// A member's picture arrived ([av] is its fingerprint, [data] the picture as base64), or with no [data] they took it
  /// away.
  void Function(String id, String? av, String? data) onAvatar = (_, _, _) {};
  void Function(Connection connection) onConnection = (_) {};

  Connection _connection = Connection.connecting;
  Connection get connection => _connection;

  /// Shown to the others; sent again on every reconnect.
  String name;

  /// This device's own picture, as base64; shared with the room once the server says it can keep pictures.
  String? _avatar;

  /// What the server last said it can do, and whether the picture went out on this connection.
  int _serverProtocol = 0;
  bool _avatarSent = false;

  /// The `push.set` of this device (see [Wire.pushSet]), or null when it wants no notices; sent once per connection.
  String? _push;
  bool _pushSent = false;

  /// The fingerprint of each member's picture as last asked for, so a picture is fetched once and not at every change.
  final _known = <String, String>{};

  /// The fingerprint of the picture behind the chat that was last asked for.
  String? _knownBackground;

  /// What the room calls this device: members are listed by a public id, not by [clientId].
  String? _you;

  Job? _loop;
  RoomSocket? _socket;
  Completer<int>? _closing;
  bool? _createOnJoin;
  int _lastPongMs = 0;
  Completer<void> _wake = Completer<void>();

  void _set(Connection value) {
    _connection = value;
    onConnection(value);
  }

  void start() {
    if (_loop != null) return;
    _loop = Job.launch(_connectLoop, onError: (e, _) => log('connection loop failed: $e'));
  }

  bool send(String text) {
    final socket = _socket;
    if (socket == null) return false;
    socket.send(text);
    return true;
  }

  /// Sets, or with null takes away, the picture the others see of this device. Sent again on every reconnect.
  void setAvatar(String? data) {
    _avatar = data;
    if (_serverProtocol >= _avatarProtocol) send(Wire.avatarSet(data));
  }

  /// Sets, or with null takes away, the notices of the chat this device asks the server for while it is away. Sent
  /// again on every reconnect.
  void setPush(String? message) {
    final was = _push;
    _push = message;
    if (_serverProtocol < _pushProtocol) return;
    if (message != null) {
      send(message);
      _pushSent = true;
    } else if (was != null) {
      send(Wire.pushClear());
    }
  }

  /// Changes the display name without dropping the connection: the server accepts a second join.
  void rename(String newName) {
    name = newName;
    send(Wire.join(clientId, newName));
  }

  /// The network changed or came back: do not wait out the backoff, and replace a connection that may be dead without
  /// knowing it.
  void reconnectNow() {
    if (_loop == null) return;
    if (_connection == Connection.connected) _drop();
    if (!_wake.isCompleted) _wake.complete();
  }

  /// Leaves on purpose: tells the room, so an owner hands it over, then closes.
  void leave() {
    send(Wire.bye());
    close();
  }

  void close() {
    _loop?.cancel();
    _loop = null;
    _socket?.close(1000, 'leaving');
    _socket = null;
    _set(Connection.closed);
  }

  void _drop() {
    final closing = _closing;
    if (closing != null && !closing.isCompleted) closing.complete(-1);
    _socket?.close(4000, 'reconnecting');
    _socket = null;
  }

  Future<void> _connectLoop(Job job) async {
    var attempt = 0;
    while (job.isActive) {
      _set(attempt == 0 ? Connection.connecting : Connection.reconnecting);
      final closed = _closing = Completer<int>();
      var everOpened = false;
      Job? pinger;
      late final RoomSocket ws;
      ws = _opener(
        _url,
        onOpen: () {
          everOpened = true;
          attempt = 0;
          _socket = ws;
          _lastPongMs = nowMs();
          _avatarSent = false;
          _pushSent = false;
          _set(Connection.connected);
          log('connected to $_url');
          ws.send(Wire.join(clientId, name, create: _createOnJoin));
          pinger = Job.launch((p) => _pingLoop(p, ws));
          onConnected();
        },
        onMessage: _onText,
        onClose: (code, wasOpen) {
          if (!everOpened && !wasOpen) log('connection failed');
          if (!closed.isCompleted) closed.complete(everOpened || wasOpen ? code : -1);
        },
      );

      int code;
      try {
        code = await Future.any([closed.future, job.cancelled.then((_) => -2)]);
      } finally {
        pinger?.cancel();
        ws.close(1000, 'done');
        if (identical(_socket, ws)) _socket = null;
      }
      job.check();

      if (code == -1 && !everOpened) {
        // Never opened: a wrong key shows up as a plain failure in a browser, so ask the server
        if (await probeAuth() == 401) {
          log('the server rejected our key, giving up');
          _set(Connection.unauthorized);
          return;
        }
        job.check();
      }
      if (code == _closePolicyViolation || code == _closeRemoved || code == _closeNotFound) {
        // The server refuses us (room full, removed by the owner, no such room); retrying would not help
        log('server refused the connection ($code), giving up');
        _set(Connection.refused);
        return;
      }
      final wait = _backoff(attempt++);
      log('reconnecting in ${wait.inMilliseconds}ms');
      _wake = Completer<void>();
      await Future.any([Future<void>.delayed(wait), _wake.future, job.cancelled]);
      job.check();
    }
  }

  void _onText(String text) {
    final msg = parseServerMessage(text);
    switch (msg) {
      case null:
        log('ignoring unparsable message');
      case PongMessage():
        _lastPongMs = nowMs();
        clock.addSample(msg.c0, nowMs(), msg.s1);
      case AvatarMessage():
        final av = msg.av;
        if (msg.id == Wire.backgroundId) {
          _knownBackground = av;
        } else if (av != null) {
          _known[msg.id] = av;
        } else {
          _known.remove(msg.id);
        }
        onAvatar(msg.id, av, msg.data);
      case StateMessage():
        if (_createOnJoin == true) _createOnJoin = false;
        _you = msg.you;
        _serverProtocol = msg.protocol;
        _shareAvatar();
        _sharePush();
        _wantPictures(msg.members);
        _wantBackground(msg.state.bg);
        onMessage(msg);
      case MembersMessage():
        _wantPictures(msg.members);
        onMessage(msg);
      default:
        onMessage(msg);
    }
  }

  /// Hands the room this device's picture, once per connection, when the server can keep it.
  void _shareAvatar() {
    if (_avatarSent || _serverProtocol < _avatarProtocol) return;
    _avatarSent = true;
    send(Wire.avatarSet(_avatar));
  }

  /// Asks the server for the notices of the chat, once per connection, when it can send them.
  void _sharePush() {
    final message = _push;
    if (_pushSent || message == null || _serverProtocol < _pushProtocol) return;
    _pushSent = true;
    send(message);
  }

  /// Asks for the picture behind the chat when it is a new one, and tells that it went when it did.
  void _wantBackground(String? bg) {
    if (_serverProtocol < _themeProtocol || bg == _knownBackground) return;
    _knownBackground = bg;
    if (bg == null) {
      onAvatar(Wire.backgroundId, null, null);
    } else {
      send(Wire.avatarGet(Wire.backgroundId));
    }
  }

  /// Asks for the pictures of members whose picture changed since it was last fetched, and forgets those who are gone.
  void _wantPictures(List<Member> members) {
    if (_serverProtocol < _avatarProtocol) return;
    final ids = {for (final m in members) m.id};
    _known.removeWhere((id, _) => !ids.contains(id));
    for (final member in members) {
      if (member.id == clientId || member.id == _you) continue;
      final av = member.av;
      if (av == null) {
        // They had one and took it away
        if (_known.remove(member.id) != null) onAvatar(member.id, null, null);
      } else if (_known[member.id] != av) {
        _known[member.id] = av;
        send(Wire.avatarGet(member.id));
      }
    }
  }

  /// A quick burst right after connecting for a good first estimate, then a slow refresh. A connection that stopped
  /// answering without saying so is dropped here, since nothing else would notice.
  Future<void> _pingLoop(Job job, RoomSocket ws) async {
    for (var i = 0; i < _burstPings; i++) {
      ws.send(Wire.ping(nowMs(), clock.bestRttMs));
      await job.delay(_burstGap);
    }
    while (true) {
      await job.delay(pingEvery);
      if (nowMs() - _lastPongMs > pongDeadline.inMilliseconds) {
        log('no answer to pings for ${(nowMs() - _lastPongMs) ~/ 1000}s, dropping the connection');
        _drop();
        return;
      }
      ws.send(Wire.ping(nowMs(), clock.bestRttMs));
    }
  }

  Duration _backoff(int attempt) =>
      Duration(milliseconds: (1000 << (attempt > 4 ? 4 : attempt)).clamp(0, 15000));

  /// The first protocol whose server keeps the pictures.
  static const _avatarProtocol = 8;

  /// The first protocol whose server has a theme for the chat, and a picture behind it.
  static const _themeProtocol = 16;

  /// The first protocol whose server sends notices of the chat to a browser that is away.
  static const _pushProtocol = 13;
  static const _closePolicyViolation = 1008;
  static const _closeRemoved = 4001;
  static const _closeNotFound = 4004;
  static const _burstPings = 8;
  static const _burstGap = Duration(milliseconds: 250);
}
