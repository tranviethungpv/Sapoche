/// What a phone needs to talk to the room server: where it is and the key it asks for. Another phone that has
/// them shows them as a link, `sapoche://setup?server=…&key=…`, usually inside a QR code.
class SetupLink {
  const SetupLink({required this.server, required this.key});

  final String server;
  final String key;

  /// The address a person recognises: no scheme, no path.
  String get host => Uri.parse(server).host;

  /// The server and key in [text], or null when it is not a setup link. Anything around the link is ignored, so a
  /// link pasted from a message still works.
  static SetupLink? parse(String text) {
    final found = RegExp(r'sapoche://setup\?\S+').firstMatch(text);
    final uri = found == null ? null : Uri.tryParse(found.group(0)!);
    if (uri == null) return null;
    var server = (uri.queryParameters['server'] ?? '').trim();
    while (server.endsWith('/')) {
      server = server.substring(0, server.length - 1);
    }
    final address = Uri.tryParse(server);
    // Only an https address: the key is sent to it with every call
    if (address == null || address.scheme != 'https' || address.host.isEmpty) {
      return null;
    }
    return SetupLink(
      server: server,
      key: (uri.queryParameters['key'] ?? '').trim(),
    );
  }
}
