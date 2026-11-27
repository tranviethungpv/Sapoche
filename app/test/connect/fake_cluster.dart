import 'dart:async';
import 'dart:convert';

import 'package:sapoche/data/web/room_socket.dart';

/// The server of Connect in a few lines, for tests that need no Worker: one cluster, its devices and the same messages as
/// server/src/connect.ts (the real one is tested against the same cases by server/scripts/sim-connect.mjs, and by
/// `connect_server_test.dart` with the real Worker). Messages go by microtask, as they would over a socket.
class FakeCluster {
  final _conns = <_Conn>[];
  String? _auth;
  String? active;
  Map<String, Object?>? state;
  String? queue;
  ({String from, String to})? _pending;
  var clockOffsetMs = 0;

  /// Everything the devices sent, for a test to look at: `[clientId, message]`.
  final sent = <(String, Map<String, dynamic>)>[];

  SocketOpener get opener => (url, {required onOpen, required onMessage, required onClose}) {
    final conn = _Conn(this, onMessage, onClose);
    scheduleMicrotask(onOpen);
    return conn;
  };

  /// Cuts the line of the device [clientId] as a network that drops would.
  void drop(String clientId) {
    for (final c in _conns.where((c) => c.clientId == clientId).toList()) {
      c.closeFromServer(1006);
    }
  }

  List<Map<String, Object?>> get _devices {
    final byId = <String, String>{};
    for (final c in _conns) {
      if (c.id != null) byId[c.id!] = c.info;
    }
    return [for (final e in byId.entries) {'id': e.key, 'info': e.value}];
  }

  _Conn? _find(String id) => _conns.where((c) => c.id == id).firstOrNull;

  void _broadcast(Map<String, Object?> m, {_Conn? except}) {
    for (final c in _conns) {
      if (c != except && c.id != null) c.deliver(m);
    }
  }

  void _setActive(String? id) {
    active = id;
    _broadcast({'t': 'active', 'device': id});
  }

  void _handle(_Conn c, Map<String, dynamic> m) {
    sent.add((c.clientId ?? '?', m));
    switch (m['t']) {
      case 'ping':
        c.deliver({'t': 'pong', 'c0': m['c0'], 's1': DateTime.now().millisecondsSinceEpoch + clockOffsetMs});
      case 'hello':
        final token = m['token'] as String;
        if (_auth != null && _auth != token) {
          c.deliver({'t': 'error', 'code': 'bad_token'});
          c.closeFromServer(4001);
          return;
        }
        _auth = token;
        c.clientId = m['clientId'] as String;
        c.id = c.clientId!.substring(0, 8);
        c.info = m['info'] as String? ?? '';
        for (final other in _conns.where((o) => o != c && o.id == c.id).toList()) {
          other.id = null;
          other.closeFromServer(4000);
        }
        c.deliver({'t': 'welcome', 'v': 1, 'you': c.id, 'devices': _devices, 'active': active, 'state': state, 'queue': queue, 'now': DateTime.now().millisecondsSinceEpoch});
        _broadcast({'t': 'devices', 'devices': _devices, 'active': active}, except: c);
      case 'info':
        c.info = m['info'] as String;
        _broadcast({'t': 'devices', 'devices': _devices, 'active': active});
      case 'state':
        if (active != c.id) return c.deliver({'t': 'error', 'code': 'not_active'});
        state = {'rev': m['rev'], 'blob': m['blob'], 'at': DateTime.now().millisecondsSinceEpoch};
        _broadcast({'t': 'state', 'from': c.id, 'rev': m['rev'], 'blob': m['blob']}, except: c);
      case 'queue':
        if (active != c.id) return c.deliver({'t': 'error', 'code': 'not_active'});
        queue = m['blob'] as String;
        _broadcast({'t': 'queue', 'from': c.id, 'blob': m['blob']}, except: c);
      case 'cmd':
        final to = _find(m['to'] as String);
        if (to == null) return c.deliver({'t': 'error', 'code': 'gone'});
        to.deliver({'t': 'cmd', 'from': c.id, 'blob': m['blob']});
      case 'transfer':
        final to = m['to'] as String;
        if (_find(to) == null) return c.deliver({'t': 'error', 'code': 'gone'});
        if (active == to) return;
        if (active == null || _find(active!) == null) return _finish(to, queue, null);
        _pending = (from: active!, to: to);
        _find(active!)!.deliver({'t': 'release', 'to': to, 'by': c.id});
      case 'handoff':
        final p = _pending;
        if (p == null || p.from != c.id) return;
        queue = m['blob'] as String;
        _finish(p.to, queue, p.from);
      case 'claim':
        final from = active;
        _pending = null;
        if (from != null && from != c.id) _find(from)?.deliver({'t': 'deposed', 'by': c.id});
        queue = null;
        state = null;
        _setActive(c.id);
      case 'stop':
        if (active == c.id) _setActive(null);
      case 'bye':
        c.closeFromServer(1000);
    }
  }

  void _finish(String to, String? blob, String? from) {
    _pending = null;
    state = null;
    _setActive(to);
    _find(to)?.deliver({'t': 'handoff', 'from': from, 'blob': blob});
  }

  void _closed(_Conn c) {
    _conns.remove(c);
    final id = c.id;
    if (id == null || _find(id) != null) return;
    final p = _pending;
    if (p != null && p.from == id) _finish(p.to, queue, null);
    if (active == id) _setActive(null);
    _broadcast({'t': 'devices', 'devices': _devices, 'active': active});
  }
}

class _Conn implements RoomSocket {
  _Conn(this.cluster, this.onMessage, this.onClose) {
    cluster._conns.add(this);
  }

  final FakeCluster cluster;
  final void Function(String text) onMessage;
  final void Function(int code, bool wasOpen) onClose;
  String? clientId;
  String? id;
  String info = '';
  var _closed = false;

  void deliver(Map<String, Object?> m) {
    final text = jsonEncode(m);
    scheduleMicrotask(() {
      if (!_closed) onMessage(text);
    });
  }

  void closeFromServer(int code) {
    if (_closed) return;
    _closed = true;
    cluster._closed(this);
    scheduleMicrotask(() => onClose(code, true));
  }

  @override
  void send(String text) {
    if (_closed) return;
    final m = jsonDecode(text) as Map<String, dynamic>;
    scheduleMicrotask(() {
      if (!_closed) cluster._handle(this, m);
    });
  }

  @override
  void close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    cluster._closed(this);
  }
}
