import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/media_crypto.dart';

// The file cipher against the vector in the file the other ciphers read as well (made with Node's own crypto).
void main() {
  final vectors = jsonDecode(
    File('../native/sync/src/test/resources/e2ee_vectors.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final vector = vectors['file'] as Map<String, dynamic>;
  List<int> unb64(String text) => base64Url.decode(base64Url.normalize(text));
  final key = unb64(vector['key'] as String);
  final plaintext = unb64(vector['plaintext'] as String);
  final file = unb64(vector['file'] as String);

  test('seals what the vector says and opens it', () async {
    final sealed = await MediaCrypto.seal(
      plaintext,
      key: key,
      nonce: unb64(vector['nonce'] as String),
    );
    expect(sealed.file, file);
    expect(sealed.key, vector['key']);
    expect(
      await MediaCrypto.open(file, vector['key'] as String, sha: sealed.sha),
      plaintext,
    );
  });

  test(
    'a file gets a key of its own and is never sealed the same way twice',
    () async {
      final a = await MediaCrypto.seal(plaintext);
      final b = await MediaCrypto.seal(plaintext);
      expect(a.key, isNot(b.key));
      expect(a.file, isNot(b.file));
      expect(a.file.length, plaintext.length + 12 + 16);
      expect(await MediaCrypto.open(a.file, a.key, sha: a.sha), plaintext);
    },
  );

  test('does not open a file for another key, or one that was touched or is not the one that was announced', () async {
    final sealed = await MediaCrypto.seal(plaintext);
    expect(
      await MediaCrypto.open(
        sealed.file,
        (await MediaCrypto.seal(plaintext)).key,
      ),
      isNull,
    );
    final touched = Uint8List.fromList(sealed.file)..[20] ^= 1;
    expect(await MediaCrypto.open(touched, sealed.key), isNull);
    expect(
      await MediaCrypto.open(sealed.file, sealed.key, sha: 'AAAA'),
      isNull,
    );
    expect(await MediaCrypto.open(Uint8List(10), sealed.key), isNull);
    expect(await MediaCrypto.open(sealed.file, 'not a key'), isNull);
  });
}
