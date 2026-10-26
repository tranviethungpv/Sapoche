import 'dart:async';

import 'clocks.dart';
import 'job.dart';
import 'room_socket.dart';
import 'wire.dart';

/// [refused]: the server turned this device away for good (room full, no such room, removed by the owner).
enum Connection { connecting, connected, reconnecting, closed, unauthorized, refused }

/// WebSocket connection to one room. Joins on every (re)connect, keeps the clock offset fresh with pings, and
/// reconnects with exponential backoff when the connection drops. Mirrors RoomClient.kt, except for the pictures of
/// the members, which are not fetched yet.
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
  void Function(Connection connection) onConnection = (_) {};

  Connection _connection = Connection.connecting;
  Connection get connection => _connection;

  /// Shown to the others; sent again on every reconnect.
  String name;

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
      case StateMessage():
        if (_createOnJoin == true) _createOnJoin = false;
        onMessage(msg);
      default:
        onMessage(msg);
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

  static const _closePolicyViolation = 1008;
  static const _closeRemoved = 4001;
  static const _closeNotFound = 4004;
  static const _burstPings = 8;
  static const _burstGap = Duration(milliseconds: 250);
}
