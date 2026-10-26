import 'dart:io';

import 'room_socket.dart';

/// dart:io WebSocket, for tests that talk to a local server.
RoomSocket openSocket(
  Uri url, {
  required void Function() onOpen,
  required void Function(String text) onMessage,
  required void Function(int code, bool wasOpen) onClose,
}) => _IoSocket(url, onOpen, onMessage, onClose);

class _IoSocket implements RoomSocket {
  _IoSocket(Uri url, this.onOpen, this.onMessage, this.onClose) {
    WebSocket.connect(url.toString()).then(
      (ws) {
        if (_closed) {
          ws.close();
          return;
        }
        _ws = ws;
        onOpen();
        ws.listen(
          (data) {
            if (data is String) onMessage(data);
          },
          onDone: () => _done(ws.closeCode ?? 1006, true),
          onError: (Object _) => _done(1006, true),
        );
      },
      onError: (Object _) => _done(1006, false),
    );
  }

  final void Function() onOpen;
  final void Function(String text) onMessage;
  final void Function(int code, bool wasOpen) onClose;
  WebSocket? _ws;
  bool _closed = false;

  void _done(int code, bool wasOpen) {
    if (_closed) return;
    _closed = true;
    onClose(code, wasOpen);
  }

  @override
  void send(String text) => _ws?.add(text);

  @override
  void close(int code, String reason) {
    _closed = true;
    _ws?.close(code, reason);
  }
}
