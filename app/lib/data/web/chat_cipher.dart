import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models.dart';

/// End-to-end encryption of a room's chat (protocol 15). The room has one secret of 32 bytes, made on the device of its
/// owner and handed to the others in the invitation link, never through the server. The key for a message is
/// HKDF-SHA256 of that secret, salted with a label and bound to the room's code and a key epoch; a message is sealed with
/// AES-256-GCM, with the sender and the room as associated data, so the server can neither move it to another room nor
/// sign it with another member's name. Mirrors ChatCipher.kt and ChatCipher.swift; the three read the same vectors
/// (`native/sync/src/test/resources/e2ee_vectors.json`). In a browser the work is the browser's own (WebCrypto).
///
/// A sealed message is base64url of: version (1), epoch (1), nonce (12), ciphertext and tag. What is sealed is JSON,
/// `{"t": text, "q": the quote of the message answered}`, padded with spaces to a multiple of 64 bytes so that its length
/// says little. The preview, for a notice, is the first 120 characters sealed apart.
class ChatCipher {
  const ChatCipher._();

  static const _label = 'sapoche-chat-v1';
  static const _version = 1;
  static const _nonceBytes = 12;
  static const _tagBytes = 16;
  static const _pad = 64;
  static const _previewChars = 120;

  /// The epoch a new message is sealed in: one until keys can be changed.
  static const epoch = 1;

  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _random = Random.secure();

  /// A new secret for a room.
  static Uint8List newSecret() => _randomBytes(32);

  static Uint8List _randomBytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

  static String encodeSecret(List<int> secret) => _encode(secret);

  /// The secret in [text] (as in an invitation link), or null when it is not one.
  static Uint8List? decodeSecret(String text) {
    final bytes = _decode(text.trim());
    return bytes != null && bytes.length == 32 ? bytes : null;
  }

  /// The key of [epoch] for room [room].
  static Future<SecretKey> key(List<int> secret, String room, [int epoch = ChatCipher.epoch]) => _hkdf.deriveKey(
    secretKey: SecretKey(secret),
    nonce: utf8.encode(_label),
    info: utf8.encode('${room.toUpperCase()}|$epoch'),
  );

  static List<int> _associated(String room, String by, int epoch, bool preview) =>
      utf8.encode('$_label|${room.toUpperCase()}|$by|$epoch${preview ? '|pv' : ''}');

  /// [plaintext] sealed for [by] in [room]. [nonce] is only given by the tests.
  static Future<String> seal(
    List<int> secret,
    String room,
    String by,
    List<int> plaintext, {
    bool preview = false,
    int epoch = ChatCipher.epoch,
    List<int>? nonce,
  }) async {
    final iv = nonce ?? _randomBytes(_nonceBytes);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: await key(secret, room, epoch),
      nonce: iv,
      aad: _associated(room, by, epoch, preview),
    );
    return _encode([_version, epoch, ...iv, ...box.cipherText, ...box.mac.bytes]);
  }

  /// What [envelope], sent by [by] in [room], holds; null when it is not from this room's secret, this sender, or intact.
  static Future<Uint8List?> open(
    List<int> secret,
    String room,
    String by,
    String envelope, {
    bool preview = false,
  }) async {
    final bytes = _decode(envelope);
    if (bytes == null || bytes.length < 2 + _nonceBytes + _tagBytes || bytes[0] != _version) return null;
    final epoch = bytes[1];
    try {
      final box = SecretBox(
        bytes.sublist(2 + _nonceBytes, bytes.length - _tagBytes),
        nonce: bytes.sublist(2, 2 + _nonceBytes),
        mac: Mac(bytes.sublist(bytes.length - _tagBytes)),
      );
      return Uint8List.fromList(
        await _aes.decrypt(box, secretKey: await key(secret, room, epoch), aad: _associated(room, by, epoch, preview)),
      );
    } on Object {
      return null;
    }
  }

  /// The sealed words of a message by [by], with the quote of what it answers inside, and the sealed preview.
  static Future<({String ct, String pv})> sealMessage(
    List<int> secret,
    String room,
    String by,
    String text,
    ChatQuote? quote,
  ) async {
    final body = utf8.encode(
      jsonEncode({
        't': text,
        if (quote != null) 'q': {'id': quote.id, 'by': quote.by, 'name': quote.name, 'text': quote.text},
      }),
    );
    final padded = [...body, ...List.filled((_pad - body.length % _pad) % _pad, 0x20)];
    final cut = String.fromCharCodes(text.runes.take(_previewChars));
    return (
      ct: await seal(secret, room, by, padded),
      pv: await seal(secret, room, by, utf8.encode(cut), preview: true),
    );
  }

  /// [message] as the room sent it, with its words read: the text and the quote of what it answers. Null when it is not
  /// sealed or cannot be read with [secret].
  static Future<ChatMessage?> openMessage(List<int> secret, String room, ChatMessage message) async {
    final ct = message.ct;
    if (ct == null) return null;
    final body = await open(secret, room, message.by, ct);
    if (body == null) return null;
    try {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final q = json['q'] as Map<String, dynamic>?;
      return message.sealedAs(text: json['t'] as String, reply: q == null ? null : ChatQuote.fromJson(q));
    } on Object {
      return null;
    }
  }

  static String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List? _decode(String text) {
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      return null;
    }
  }
}
