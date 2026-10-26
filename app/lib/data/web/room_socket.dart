import 'room_socket_io.dart' if (dart.library.js_interop) 'room_socket_web.dart';

/// A WebSocket as the room connection needs it. Two implementations: the browser's, and dart:io's for tests.
abstract class RoomSocket {
  void send(String text);
  void close(int code, String reason);
}

/// Opens [url]. [onClose] gets the close code, or 1006 when the connection never opened or dropped; [wasOpen] says
/// whether it had opened, since a browser says nothing else about why a connection could not be made.
typedef SocketOpener = RoomSocket Function(
  Uri url, {
  required void Function() onOpen,
  required void Function(String text) onMessage,
  required void Function(int code, bool wasOpen) onClose,
});

SocketOpener get defaultSocketOpener => openSocket;
