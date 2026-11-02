import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A picture sealed for the room's bucket: [file] is what is put there, [key] what opens it and [sha] its SHA-256, both
/// to travel in the message (which is sealed itself in a room with end-to-end encryption).
class SealedFile {
  const SealedFile({required this.key, required this.sha, required this.file});

  /// 32 random bytes, base64url without padding.
  final String key;

  /// SHA-256 of [file], base64url without padding.
  final String sha;

  /// The nonce (12 bytes), the encrypted bytes and the tag (16 bytes).
  final Uint8List file;
}

/// Seals and opens the files that go with chat messages. Each file gets a key of its own, so the bucket and the server hold
/// opaque bytes whether or not the room's chat is sealed: AES-256-GCM over the whole file, with no associated data (the
/// key is used once). The same on every platform; the vector is in `e2ee_vectors.json` under `file`.
class MediaCrypto {
  const MediaCrypto._();

  static const _nonceBytes = 12;
  static const _tagBytes = 16;

  static final _aes = AesGcm.with256bits();
  static final _random = Random.secure();

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

  /// [bytes] under a new key. [key] and [nonce] are only given by the tests.
  static Future<SealedFile> seal(
    List<int> bytes, {
    List<int>? key,
    List<int>? nonce,
  }) async {
    final secret = key ?? _randomBytes(32);
    final box = await _aes.encrypt(
      bytes,
      secretKey: SecretKey(secret),
      nonce: nonce ?? _randomBytes(_nonceBytes),
    );
    final file = Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    return SealedFile(
      key: _encode(secret),
      sha: _encode((await Sha256().hash(file)).bytes),
      file: file,
    );
  }

  /// What [file] holds under [key] (base64url); null when [sha], if given, is not the file's, or it was not sealed with the
  /// key, or was touched.
  static Future<Uint8List?> open(
    List<int> file,
    String key, {
    String? sha,
  }) async {
    final secret = _decode(key);
    if (secret == null || secret.length != 32 || file.length < _nonceBytes + _tagBytes) return null;
    try {
      if (sha != null && _encode((await Sha256().hash(file)).bytes) != sha) return null;
      final box = SecretBox(
        file.sublist(_nonceBytes, file.length - _tagBytes),
        nonce: file.sublist(0, _nonceBytes),
        mac: Mac(file.sublist(file.length - _tagBytes)),
      );
      return Uint8List.fromList(
        await _aes.decrypt(box, secretKey: SecretKey(secret)),
      );
    } on Object {
      return null;
    }
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List? _decode(String text) {
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      return null;
    }
  }
}
