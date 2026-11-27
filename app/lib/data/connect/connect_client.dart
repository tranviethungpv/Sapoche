import 'dart:async';
import 'dart:convert';

import '../web/room_socket.dart';
import 'connect_keys.dart';

/// Where the connection to the cluster stands.
enum ConnectLink {
  /// Not connecting: no key, or turned off.
  off,
  connecting,
  online,

  /// The server cannot be reached; it is tried again.
  offline,

  /// The server will not have this device (a wrong token, or twelve devices already): it is not tried again.
  refused,
}

/// What the server says in a message, with the text of the sealed parts left as they came.
typedef ConnectMessage = Map<String, dynamic>;

/// The connection of one device to its cluster on the server (docs/PROTOCOL.md "Connect"): hello, ping, the sending of
/// messages, and trying again when the line drops. It knows nothing of what the messages mean; [ConnectController] does.
class ConnectClient {
  ConnectClient({
    required this.secrets,
    required this.clientId,
    required this.address,
    required this.info,
    required this.onMessage,
    required this.onLink,
    SocketOpener? opener,
    this.pingEvery = const Duration(seconds: 45),
    this.probeAfter = const Duration(seconds: 6),
    this.retryFirst = const Duration(seconds: 1),
    this.retryMax = const Duration(seconds: 30),
    int Function()? nowMs,
  }) : _open = opener ?? defaultSocketOpener,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ConnectSecrets secrets;

  /// This device's secret id; the server derives the public one.
  final String clientId;

  /// The address of the WebSocket: the server, the cluster and the key of the group, which change (the key is read when asked).
  final Future<Uri> Function() address;

  /// What this device says about itself, sealed.
  final Future<String> Function() info;
  final void Function(ConnectMessage message) onMessage;
  final void Function(ConnectLink link) onLink;
  final SocketOpener _open;
  final Duration pingEvery;

  /// How long an answer to a ping that is sent to find out whether the line still lives may take (when the app comes back).
  final Duration probeAfter;
  final Duration retryFirst;
  final Duration retryMax;
  final int Function() _now;

  RoomSocket? _socket;
  Timer? _pingTimer;
  Timer? _probe;
  var _heardAt = 0;
  Timer? _retryTimer;
  var _retry = Duration.zero;
  var _stopped = true;
  var _generation = 0;
  ConnectLink _link = ConnectLink.off;
  ConnectLink get link => _link;

  /// What to add to this device's clock to get the server's, from the last ping; 0 until one was answered.
  int clockOffsetMs = 0;
  var _rtt = 0;
  int get roundTripMs => _rtt;

  /// The clock of the server now.
  int get serverNow => _now() + clockOffsetMs;

  void _set(ConnectLink link) {
    if (_link == link) return;
    _link = link;
    onLink(link);
  }

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _retry = Duration.zero;
    unawaited(_connect());
  }

  void stop() {
    _stopped = true;
    _generation++;
    _pingTimer?.cancel();
    _probe?.cancel();
    _retryTimer?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.send(jsonEncode({'t': 'bye'}));
      } on Object {
        // closing anyway
      }
      socket.close(1000, 'bye');
    }
    _set(ConnectLink.off);
  }

  Future<void> _connect() async {
    if (_stopped) return;
    final generation = ++_generation;
    _set(ConnectLink.connecting);
    final Uri url;
    final String sealedInfo;
    try {
      url = await address();
      sealedInfo = await info();
    } on Object {
      if (generation == _generation) _scheduleRetry();
      return;
    }
    if (_stopped || generation != _generation) return;
    _socket = _open(
      url,
      onOpen: () {
        if (generation != _generation) return;
        _heardAt = _now();
        _send({'t': 'hello', 'v': 1, 'token': secrets.token, 'clientId': clientId, 'info': sealedInfo});
        _ping();
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(pingEvery, (_) {
          // The server answers every ping: two went by with nothing heard, and the line is dead without having said so (a
          // network that went away leaves a socket that is open for as long as the system takes to find out)
          if (_now() - _heardAt > pingEvery.inMilliseconds * 2) return _lost();
          _ping();
        });
      },
      onMessage: (text) {
        if (generation != _generation) return;
        _heardAt = _now();
        final Object? decoded;
        try {
          decoded = jsonDecode(text);
        } on FormatException {
          return;
        }
        if (decoded is! Map<String, dynamic>) return;
        switch (decoded['t']) {
          case 'pong':
            final c0 = (decoded['c0'] as num?)?.toInt();
            final s1 = (decoded['s1'] as num?)?.toInt();
            if (c0 == null || s1 == null) return;
            final now = _now();
            _rtt = now - c0;
            clockOffsetMs = s1 - (c0 + _rtt ~/ 2);
          case 'welcome':
            _retry = Duration.zero;
            _set(ConnectLink.online);
            onMessage(decoded);
          case 'error' when decoded['code'] == 'bad_token' || decoded['code'] == 'full':
            _set(ConnectLink.refused);
            onMessage(decoded);
          default:
            onMessage(decoded);
        }
      },
      onClose: (code, wasOpen) {
        if (generation != _generation) return;
        _pingTimer?.cancel();
        _socket = null;
        // 4001: not let in; 4000: the same device came by another line, which keeps the place
        if (code == 4001 || code == 4000 || _stopped) {
          _set(code == 4001 ? ConnectLink.refused : ConnectLink.off);
          return;
        }
        _set(ConnectLink.offline);
        _scheduleRetry();
      },
    );
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _set(ConnectLink.offline);
    _retry = _retry == Duration.zero ? retryFirst : (_retry * 2 > retryMax ? retryMax : _retry * 2);
    _retryTimer?.cancel();
    _retryTimer = Timer(_retry, () => unawaited(_connect()));
  }

  /// The line is dead: it is closed and made again.
  void _lost() {
    _pingTimer?.cancel();
    _probe?.cancel();
    final socket = _socket;
    _socket = null;
    _generation++;
    if (socket != null) socket.close(4002, 'silent');
    _scheduleRetry();
  }

  /// The app came back to the front, or the network came back: a line that was lost is tried again now, and one that seems to
  /// live is asked, and made again if it does not answer.
  void nudge() {
    if (_stopped || _link == ConnectLink.connecting || _link == ConnectLink.refused) return;
    if (_link == ConnectLink.online) {
      final asked = _now();
      _ping();
      _probe?.cancel();
      _probe = Timer(probeAfter, () {
        if (_heardAt < asked && _link == ConnectLink.online) _lost();
      });
      return;
    }
    _retryTimer?.cancel();
    unawaited(_connect());
  }

  void _ping() => _send({'t': 'ping', 'c0': _now()});

  /// Sends [message]; false when there is no open line to send it on.
  bool send(ConnectMessage message) => _link == ConnectLink.online && _send(message);

  bool _send(ConnectMessage message) {
    final socket = _socket;
    if (socket == null) return false;
    socket.send(jsonEncode(message));
    return true;
  }
}
