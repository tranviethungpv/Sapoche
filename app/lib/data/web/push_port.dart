import '../models.dart';

/// Whether a browser can be given notices of the chat.
enum PushSupport {
  none,

  /// An iPhone shows notices of a web page only once the page is on the Home Screen.
  needsInstall,
  ready,
}

/// What [WebBackend] needs of the browser to tell the person of the chat while the page is not in front: the permission, the
/// subscription to the push service of the browser, and the touch of a notice. [push_port_web.dart] is the page's.
abstract class PushPort {
  PushSupport get support;
  NoticePermission get permission;

  /// Asks the person's leave (this must come from a touch) and subscribes with the public key of the server. Null when
  /// they refuse, or the browser cannot.
  Future<Map<String, Object?>?> subscribe(String serverKey);

  /// The subscription this browser has already, as the server takes it, or null. Asks nothing.
  Future<Map<String, Object?>?> current();

  Future<void> unsubscribe();

  /// The code of the room whose notice was touched while this page was open.
  Stream<String> get opened;
}
