import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'room_socket.dart';

/// The browser's WebSocket.
RoomSocket openSocket(
  Uri url, {
  required void Function() onOpen,
  required void Function(String text) onMessage,
  required void Function(int code, bool wasOpen) onClose,
}) => _WebSocket(url, onOpen, onMessage, onClose);

class _WebSocket implements RoomSocket {
  _WebSocket(
    Uri url,
    void Function() onOpen,
    void Function(String text) onMessage,
    void Function(int code, bool wasOpen) onClose,
  ) : _ws = web.WebSocket(url.toString()) {
    var opened = false;
    _ws.onopen = ((web.Event _) {
      opened = true;
      onOpen();
    }).toJS;
    _ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>()) onMessage((data as JSString).toDart);
    }).toJS;
    _ws.onclose = ((web.CloseEvent e) => onClose(e.code, opened)).toJS;
  }

  final web.WebSocket _ws;

  @override
  void send(String text) {
    if (_ws.readyState == web.WebSocket.OPEN) _ws.send(text.toJS);
  }

  @override
  void close(int code, String reason) {
    // Detach first: a closing socket must not report back into a session that has moved on
    _ws.onclose = null;
    _ws.onmessage = null;
    _ws.close(code, reason);
  }
}
