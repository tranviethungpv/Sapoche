import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/sticker_store.dart';

import 'png_fixture.dart';

const stickerServerAddress = 'https://stickers.test';

/// The stickers of each pack of [StickerServer]: id, emoji, keywords.
const stickersOf = <String, List<(String, String, List<String>)>>{
  'noto': [
    ('1f600', '😀', ['smile', 'happy']),
    ('1f602', '😂', ['joy', 'laugh']),
    ('1f436', '🐶', ['dog']),
  ],
  'fluent': [
    ('1f600', '😀', ['grinning']),
    ('2764', '❤', ['heart', 'love']),
  ],
  'plain': [
    ('1f44d', '👍', ['thumbs']),
    ('1f44f', '👏', ['clap']),
    ('1f525', '🔥', ['fire']),
  ],
  // More than the four of the strip in the store
  'extra': [
    ('1f389', '🎉', ['party']),
    ('1f381', '🎁', ['gift']),
    ('1f388', '🎈', ['balloon']),
    ('1f38a', '🎊', ['confetti']),
    ('1f38b', '🎋', ['tanabata']),
    ('1f38d', '🎍', ['pine']),
    ('1f38e', '🎎', ['dolls']),
    ('1f38f', '🎏', ['carp']),
  ],
};

/// The room server's `/stickers/…` files, as a test double: four packs, and what a server without them does (it answers
/// every path with its web page).
class StickerServer {
  StickerServer({this.packs = const ['noto', 'fluent', 'plain', 'extra']});

  final List<String> packs;

  /// Every path asked for, in order.
  final requests = <String>[];

  /// The server cannot be reached.
  bool down = false;

  /// The server has no stickers: every path gives its web page, with a status of 200.
  bool html = false;

  /// Sticker images (not the lists) wait for [gate] once this many have been given.
  int? holdAfter;
  Completer<void>? gate;

  /// Sticker ids that are not there.
  /// Holds the images that come after the first [after] ones until [gate] is completed.
  void hold(int after) {
    holdAfter = after;
    _images = 0;
    gate = Completer<void>();
  }

  final missing = <String>{};
  int _images = 0;

  int imageRequests(String pack) =>
      requests.where((r) => r.startsWith('/stickers/$pack/') && r.endsWith('.webp')).length;

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    requests.add(path);
    if (down) throw http.ClientException('offline');
    if (html || !path.startsWith('/stickers/')) return _page();
    final parts = path.substring('/stickers/'.length).split('/');
    if (parts.length == 1 && parts[0] == 'index.json') return _json(index());
    if (parts.length == 2 && packs.contains(parts[0])) {
      if (parts[1] == 'pack.json') return _json(pack(parts[0]));
      if (parts[1].endsWith('.webp')) {
        final id = parts[1].replaceAll('.webp', '');
        final held = holdAfter;
        if (held != null && _images++ >= held) await gate?.future;
        if (stickersOf[parts[0]]!.any((s) => s.$1 == id) && !missing.contains('${parts[0]}/$id')) {
          return http.Response.bytes(solidPng(200, 80, 80, side: 8), 200, headers: {'content-type': 'image/webp'});
        }
      }
    }
    return _page();
  });

  http.Response _page() =>
      http.Response('<!doctype html><html><body>app</body></html>', 200, headers: {'content-type': 'text/html'});

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

  Map<String, Object?> index() => {
    'v': 1,
    'packs': [
      for (final id in packs)
        {
          'id': id,
          'name': {'en': 'Pack $id', 'vi': 'Bộ $id'},
          'icon': stickersOf[id]!.first.$1,
          'count': stickersOf[id]!.length,
          'bytes': 3300000,
          'v': 1,
          'credit': {
            'name': id == 'noto' ? 'Noto Animated Emoji' : 'Art of $id',
            'by': id == 'noto' ? 'Google' : 'Someone',
            'license': id == 'noto' ? 'CC BY 4.0' : 'MIT',
            'url': 'https://example.test/$id',
          },
        },
    ],
  };

  Map<String, Object?> pack(String id) => {
    'id': id,
    'stickers': [
      for (final s in stickersOf[id]!) {'id': s.$1, 'e': s.$2, 'k': s.$3, 'g': 'faces'},
    ],
  };
}

/// [StickerDisk] in memory, by path.
class MemoryStickerDisk implements StickerDisk {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String pack, String name) async => files['$pack/$name'];

  @override
  Future<void> write(String pack, String name, Uint8List bytes) async => files['$pack/$name'] = bytes;

  @override
  Future<void> deletePack(String pack) async => files.removeWhere((path, _) => path.startsWith('$pack/'));
}

/// A store over [server]; [disk] is where the packs are kept (none, as in a browser, by default).
Future<StickerStore> stickerStore(
  StickerServer server, {
  StickerDisk? disk,
  String address = stickerServerAddress,
}) async => StickerStore(
  prefs: await SharedPreferences.getInstance(),
  server: () => address,
  disk: disk == null ? null : () async => disk,
  client: server.client,
);
