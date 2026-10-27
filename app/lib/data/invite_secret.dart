/// What an invitation link of a room says: its code and, for a room whose chat is end-to-end encrypted, the secret that
/// opens it (written after a `#`, so the server that serves the link page never sees it).
class InviteSecret {
  const InviteSecret({required this.room, this.secret});

  final String room;

  /// The secret as written in the link (base64url of 32 bytes); null when the link has none.
  final String? secret;

  static final _code = RegExp(r'^[A-Za-z0-9]{6}$');
  static final _secret = RegExp(r'^[A-Za-z0-9_-]{43}$');

  /// The room and secret in [text]: a link of the server (`https://host/join/CODE#k=...`), the app's own
  /// (`sapoche://join/CODE?k=...`), or just a code. Anything around a link is ignored. Null when there is no room in it.
  static InviteSecret? parse(String text) {
    final link = RegExp(r'(?:https?|sapoche)://\S+').firstMatch(text)?.group(0);
    if (link == null) {
      final code = text.trim();
      return _code.hasMatch(code) ? InviteSecret(room: code.toUpperCase()) : null;
    }
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final segments = [if (uri.scheme == 'sapoche') uri.host, ...uri.pathSegments];
    if (segments.length < 2 || segments[segments.length - 2] != 'join') return null;
    final code = segments.last;
    if (!_code.hasMatch(code)) return null;
    final fromFragment = Uri.splitQueryString(uri.fragment.contains('=') ? uri.fragment : '')['k'];
    final secret = fromFragment ?? uri.queryParameters['k'];
    return InviteSecret(
      room: code.toUpperCase(),
      secret: secret != null && _secret.hasMatch(secret) ? secret : null,
    );
  }
}
