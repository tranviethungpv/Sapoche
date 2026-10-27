import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/chat_cipher.dart';

// The Dart cipher against the vectors Kotlin and Swift read as well: they were made with Node's own crypto.
void main() {
  final vectors =
      jsonDecode(File('../native/sync/src/test/resources/e2ee_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final secret = ChatCipher.decodeSecret(vectors['secret'] as String)!;
  final room = vectors['code'] as String;
  List<int> unb64(String text) => base64Url.decode(base64Url.normalize(text));
  String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final cases = (vectors['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  test('derives the keys the other platforms derive', () async {
    final keys = vectors['keys'] as Map<String, dynamic>;
    for (final epoch in [1, 2]) {
      expect(hex(await (await ChatCipher.key(secret, room, epoch)).extractBytes()), keys['$epoch']);
    }
    // The code is the room's name, however it was typed
    expect(
      await (await ChatCipher.key(secret, room.toLowerCase())).extractBytes(),
      await (await ChatCipher.key(secret, room)).extractBytes(),
    );
  });

  test('seals what the other platforms seal and opens what they sealed', () async {
    for (final c in cases) {
      final by = c['by'] as String;
      final preview = c['kind'] == 'pv';
      final plaintext = unb64(c['plaintext'] as String);
      final envelope = c['envelope'] as String;
      expect(
        await ChatCipher.seal(
          secret,
          room,
          by,
          plaintext,
          preview: preview,
          epoch: c['epoch'] as int,
          nonce: unb64(c['nonce'] as String),
        ),
        envelope,
      );
      expect(await ChatCipher.open(secret, room, by, envelope, preview: preview), plaintext);
    }
  });

  test('will not open a message for another sender, room, secret or kind, or one that was touched', () async {
    final first = cases.first;
    final by = first['by'] as String;
    final envelope = first['envelope'] as String;
    expect(await ChatCipher.open(secret, room, by, envelope), isNotNull);
    expect(await ChatCipher.open(secret, room, '0a1b2c3d4e5f6071', envelope), isNull);
    expect(await ChatCipher.open(secret, 'XYZ789', by, envelope), isNull);
    expect(await ChatCipher.open(ChatCipher.newSecret(), room, by, envelope), isNull);
    expect(await ChatCipher.open(secret, room, by, envelope, preview: true), isNull);
    final bytes = unb64(envelope);
    bytes[bytes.length - 1] ^= 1;
    expect(await ChatCipher.open(secret, room, by, base64Url.encode(bytes).replaceAll('=', '')), isNull);
    expect(await ChatCipher.open(secret, room, by, 'not an envelope'), isNull);
    expect(await ChatCipher.open(secret, room, by, ''), isNull);
  });

  test('a message with its quote goes through the room and comes back readable', () async {
    const quote = ChatQuote(id: 4, by: 'b9f77f9b6e1bf750', name: 'Bình', text: 'cũ hơn');
    const text = 'Xin chào 🌸 "quoted" a/b';
    final sealed = await ChatCipher.sealMessage(secret, room, 'a1', text, quote);
    expect(sealed.ct, isNot(sealed.pv));
    final arrived = ChatMessage(id: 7, by: 'a1', name: 'Ann', text: '', at: 5, ct: sealed.ct, pv: sealed.pv);
    final read = (await ChatCipher.openMessage(secret, room, arrived))!;
    expect(read.text, text);
    expect(read.reply!.text, quote.text);
    expect(read.reply!.id, 4);
    expect(read.locked, isFalse);
    expect(utf8.decode((await ChatCipher.open(secret, room, 'a1', sealed.pv, preview: true))!), text);
    // The same words are never sealed the same way twice, and their length says little
    expect((await ChatCipher.sealMessage(secret, room, 'a1', text, quote)).ct, isNot(sealed.ct));
    final short = (await ChatCipher.sealMessage(secret, room, 'a1', 'a', null)).ct;
    final longer = (await ChatCipher.sealMessage(secret, room, 'a1', 'a' * 20, null)).ct;
    expect(short.length, longer.length);
    // Sealed for somebody else, or not sealed: nothing to read
    expect(await ChatCipher.openMessage(secret, room, ChatMessage(id: 7, by: 'other', name: '', text: '', at: 5, ct: sealed.ct)), isNull);
    expect(await ChatCipher.openMessage(secret, room, ChatMessage(id: 7, by: 'a1', name: '', text: 'plain', at: 5)), isNull);
  });

  test('a preview is cut to 120 characters', () async {
    final sealed = await ChatCipher.sealMessage(secret, room, 'a1', 'é' * 300, null);
    expect(utf8.decode((await ChatCipher.open(secret, room, 'a1', sealed.pv, preview: true))!), 'é' * 120);
  });

  test('a secret is written and read as base64url, and only 32 bytes are one', () {
    final made = ChatCipher.newSecret();
    expect(made, hasLength(32));
    expect(ChatCipher.decodeSecret(ChatCipher.encodeSecret(made)), made);
    expect(ChatCipher.decodeSecret('abc'), isNull);
    expect(ChatCipher.decodeSecret(''), isNull);
    expect(ChatCipher.encodeSecret(made), matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
  });
}
