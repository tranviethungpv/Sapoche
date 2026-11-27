import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

import '../sync/sync_crypto.dart';

/// What the sync key gives Connect (docs/PROTOCOL.md "Connect"): the name of the cluster of this person's devices on the
/// server, the proof that a device may enter it, and the key that seals everything they say to each other. Another branch of
/// the same HKDF than the library's (`sapoche-connect/…`), so that nothing of one opens the other.
class ConnectSecrets {
  const ConnectSecrets({required this.clusterId, required this.token, required this.seal});

  /// 64 hex characters: the name of the cluster.
  final String clusterId;

  /// 64 hex characters: what a device shows to be let in.
  final String token;
  final SecretKey seal;

  static Future<ConnectSecrets> of(SyncKey key) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final bytes = utf8.encode(key.code);
    Future<List<int>> part(String info) async =>
        (await (await hkdf.deriveKey(secretKey: SecretKey(bytes), info: utf8.encode('sapoche-connect/$info'))).extractBytes());
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return ConnectSecrets(clusterId: hex(await part('cluster')), token: hex(await part('token')), seal: SecretKey(await part('seal')));
  }
}

/// Seals what devices say to each other: text, packed with gzip when that is shorter, then AES-256-GCM, written in base64. The
/// server only ever carries the result.
class ConnectSeal {
  const ConnectSeal._();

  static const _format = 1;
  static const _packed = 1;
  static const _nonceBytes = 12;
  static const _tagBytes = 16;
  static final _aes = AesGcm.with256bits();
  static final _aad = utf8.encode('sapoche-connect/1');

  static Future<String> seal(String text, ConnectSecrets secrets, {List<int>? nonce}) async {
    List<int> body = utf8.encode(text);
    var flags = 0;
    if (body.length > 256) {
      final gz = GZipEncoder().encode(body);
      if (gz.length < body.length) {
        body = gz;
        flags = _packed;
      }
    }
    final box = await _aes.encrypt([flags, ...body], secretKey: secrets.seal, nonce: nonce, aad: _aad);
    return base64.encode([_format, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// The text in [blob]; null when it was sealed with another key, was touched, or is not one of ours.
  static Future<String?> open(String blob, ConnectSecrets secrets) async {
    try {
      final bytes = base64.decode(blob);
      if (bytes.length < 1 + _nonceBytes + _tagBytes + 1 || bytes[0] != _format) return null;
      final box = SecretBox(
        bytes.sublist(1 + _nonceBytes, bytes.length - _tagBytes),
        nonce: bytes.sublist(1, 1 + _nonceBytes),
        mac: Mac(bytes.sublist(bytes.length - _tagBytes)),
      );
      final plain = await _aes.decrypt(box, secretKey: secrets.seal, aad: _aad);
      final body = Uint8List.fromList(plain.sublist(1));
      return utf8.decode(plain[0] & _packed != 0 ? GZipDecoder().decodeBytes(body) : body);
    } on Object {
      return null;
    }
  }
}
