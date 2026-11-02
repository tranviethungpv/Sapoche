import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/sticker_licenses.dart';
import 'package:sapoche/data/sticker_store.dart';

import 'sticker_fixture.dart';

StickerExtra extra(String pack, String id, [String emoji = '😀']) =>
    StickerExtra(pack: pack, sticker: id, emoji: emoji);

void main() {
  late StickerServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = StickerServer();
  });

  group('the list of packs', () {
    test('is read from the server, with names, sizes and credits', () async {
      final store = await stickerStore(server);
      final packs = await store.loadIndex();
      expect(packs.map((p) => p.id), ['noto', 'fluent', 'plain', 'extra']);
      final noto = packs.first;
      expect(noto.name('en'), 'Pack noto');
      expect(noto.name('vi'), 'Bộ noto');
      expect(noto.name('fr'), 'Pack noto', reason: 'English stands in for a language the pack has no name in');
      expect(noto.count, 3);
      expect(noto.bytes, 3300000);
      expect(noto.icon, '1f600');
      expect(noto.credit?.license, 'CC BY 4.0');
      expect(noto.credit?.by, 'Google');
      expect(store.indexFetched, isTrue);
      expect(server.requests, ['/stickers/index.json']);
    });

    test('is empty when the server answers with its web page, which has a status of 200', () async {
      server.html = true;
      final store = await stickerStore(server);
      expect(await store.loadIndex(), isEmpty);
      expect(store.indexFetched, isFalse);
    });

    test('is empty when the server cannot be reached, and asked again the next time', () async {
      server.down = true;
      final store = await stickerStore(server);
      expect(await store.loadIndex(), isEmpty);
      server.down = false;
      expect(await store.loadIndex(), hasLength(4));
    });

    test('is empty with no server address, and asks nothing', () async {
      final store = await stickerStore(server, address: '');
      expect(await store.loadIndex(), isEmpty);
      expect(server.requests, isEmpty);
    });

    test('is the one kept from before while the server cannot be reached', () async {
      await (await stickerStore(server)).loadIndex();
      server.down = true;
      final later = await stickerStore(server);
      expect(await later.loadIndex(), hasLength(4));
      expect(later.indexFetched, isFalse, reason: 'it is tried again');
    });

    test('is asked once a session, unless asked again', () async {
      final store = await stickerStore(server);
      await store.loadIndex();
      await store.loadIndex();
      expect(server.requests, ['/stickers/index.json']);
      await store.loadIndex(force: true);
      expect(server.requests, hasLength(2));
    });

    test('skips what is no pack: a bad id, a bad entry', () {
      final packs = StickerStore.parseIndex('{"packs":[{"id":"../x"},3,{"id":"ok","name":{"en":"Ok"},"count":2}]}');
      expect(packs!.map((p) => p.id), ['ok']);
      expect(StickerStore.parseIndex('not json'), isNull);
      expect(StickerStore.parseIndex('{"packs":"x"}'), isNull);
    });
  });

  group('the stickers of a pack', () {
    test('are read, and kept', () async {
      final store = await stickerStore(server);
      final pack = await store.pack('noto');
      expect(pack!.stickers.map((s) => s.id), ['1f600', '1f602', '1f436']);
      expect(pack.sticker('1f436')!.emoji, '🐶');
      expect(pack.sticker('1f436')!.keywords, ['dog']);
      await store.pack('noto');
      expect(server.requests.where((r) => r.endsWith('pack.json')), hasLength(1));
      expect(store.loadedPack('noto'), same(pack));
    });

    test('are none when the server gives its web page, and for an id that is no name', () async {
      server.html = true;
      final store = await stickerStore(server);
      expect(await store.pack('noto'), isNull);
      expect(await store.pack('../etc'), isNull);
      expect(server.requests, hasLength(1));
    });

    test('are kept on the disk, and read from it when the server is out of reach', () async {
      final disk = MemoryStickerDisk();
      await (await stickerStore(server, disk: disk)).pack('noto');
      server.down = true;
      final again = await stickerStore(server, disk: disk);
      expect((await again.pack('noto'))!.stickers, hasLength(3));
    });

    test('are searched by a part of a keyword and by the emoji, not by what is not there', () {
      const sticker = Sticker(id: 'a', emoji: '😂', keywords: ['Joy', 'laugh']);
      expect(sticker.matches('joy'), isTrue);
      expect(sticker.matches('aug'), isTrue);
      expect(sticker.matches('😂'), isTrue);
      expect(sticker.matches('cry'), isFalse);
      expect(sticker.matches(''), isTrue);
    });
  });

  group('the first use', () {
    test('adds the first three packs of the list, and keeps them', () async {
      final store = await stickerStore(server, disk: MemoryStickerDisk());
      await store.ensureReady();
      expect(store.added, ['noto', 'fluent', 'plain']);
      expect(store.isAdded('extra'), isFalse);
      expect(store.addedPacks.map((p) => p.id), ['noto', 'fluent', 'plain']);
      expect((await stickerStore(server)).added, ['noto', 'fluent', 'plain']);
    });

    test('adds all that are listed when there are fewer than three', () async {
      final store = await stickerStore(StickerServer(packs: ['noto', 'fluent']));
      await store.ensureReady();
      expect(store.added, ['noto', 'fluent']);
    });

    test('decides nothing while the list cannot be had, and does it once it can', () async {
      server.down = true;
      final store = await stickerStore(server);
      await store.ensureReady();
      expect(store.added, isEmpty);
      server.down = false;
      await store.ensureReady();
      expect(store.added, ['noto', 'fluent', 'plain']);
    });

    test('does not add them again to a device that took every pack off', () async {
      final store = await stickerStore(server);
      await store.ensureReady();
      for (final id in [...store.added]) {
        await store.remove(id);
      }
      expect(store.added, isEmpty);
      final later = await stickerStore(server);
      await later.ensureReady();
      expect(later.added, isEmpty);
    });

    test('fetches the packs added in the background where there is a disk', () async {
      final disk = MemoryStickerDisk();
      final store = await stickerStore(server, disk: disk);
      await store.ensureReady();
      await Future<void>.delayed(Duration.zero);
      while (store.progressOf('noto') != null || store.state('plain') == StickerPackState.downloading) {
        await Future<void>.delayed(Duration.zero);
      }
      for (final id in ['noto', 'fluent', 'plain']) {
        expect(store.state(id), StickerPackState.ready, reason: id);
      }
      expect(disk.files.keys, containsAll(['noto/1f600.webp', 'fluent/2764.webp', 'plain/1f525.webp']));
      expect(server.imageRequests('extra'), 0);
    });
  });

  group('adding and removing a pack', () {
    test('fetches every file of it into the disk, with progress, and marks it whole', () async {
      final disk = MemoryStickerDisk();
      final store = await stickerStore(server, disk: disk);
      final progress = <double>[];
      store.addListener(() {
        final p = store.progressOf('extra');
        if (p != null) progress.add(p);
      });
      await store.add('extra');
      expect(store.isAdded('extra'), isTrue);
      expect(store.state('extra'), StickerPackState.ready);
      expect(store.progressOf('extra'), isNull);
      expect(
        disk.files.keys,
        containsAll(['extra/pack.json', 'extra/1f389.webp', 'extra/1f381.webp', 'extra/1f388.webp']),
      );
      expect(disk.files.keys, contains('extra/complete.mark'));
      expect(progress, isNotEmpty);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(progress.last, 1.0);
      expect(await stickerStore(server, disk: disk).then((s) => s.added), ['extra']);
    });

    test('is not fetched again when it is whole on the disk', () async {
      final disk = MemoryStickerDisk();
      final store = await stickerStore(server, disk: disk);
      await store.add('extra');
      final asked = server.requests.length;
      await store.download('extra');
      expect(server.requests, hasLength(asked));
    });

    test('takes its files off the disk when it is removed', () async {
      final disk = MemoryStickerDisk();
      final store = await stickerStore(server, disk: disk);
      await store.add('extra');
      await store.remove('extra');
      expect(store.isAdded('extra'), isFalse);
      expect(store.state('extra'), StickerPackState.notAdded);
      expect(disk.files.keys.where((k) => k.startsWith('extra/')), isEmpty);
      expect((await stickerStore(server, disk: disk)).added, isEmpty);
    });

    test('in a browser only records the choice: there is nothing to fetch', () async {
      final store = await stickerStore(server);
      await store.add('extra');
      expect(store.state('extra'), StickerPackState.ready);
      expect(store.needsDownload('extra'), isFalse);
      expect(server.imageRequests('extra'), 0);
      await store.remove('extra');
      expect(store.isAdded('extra'), isFalse);
    });

    test('stops where it was removed while it came down, and leaves no mark of a whole pack', () async {
      final disk = MemoryStickerDisk();
      server.holdAfter = 1;
      server.gate = Completer<void>();
      final store = await stickerStore(server, disk: disk);
      final adding = store.add('extra');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.state('extra'), StickerPackState.downloading);
      expect(store.progressOf('extra'), closeTo(1 / 8, 0.01));
      await store.remove('extra');
      server.gate!.complete();
      await adding;
      expect(store.state('extra'), StickerPackState.notAdded);
      expect(disk.files.keys, isNot(contains('extra/complete.mark')));
      expect(store.progressOf('extra'), isNull);
    });

    test('that failed halfway can be fetched again', () async {
      final disk = MemoryStickerDisk();
      server.missing.add('extra/1f381');
      final store = await stickerStore(server, disk: disk);
      await store.add('extra');
      expect(store.state('extra'), StickerPackState.notDownloaded);
      expect(store.needsDownload('extra'), isTrue);
      expect(disk.files.keys, isNot(contains('extra/complete.mark')));
      server.missing.clear();
      // A picture the server said was not there is not asked for again this session, so a fresh start
      final again = await stickerStore(server, disk: disk);
      await again.download('extra');
      expect(again.state('extra'), StickerPackState.ready);
    });

    test('is never given a name that is no name', () async {
      final store = await stickerStore(server, disk: MemoryStickerDisk());
      await store.add('../evil');
      expect(store.added, isEmpty);
    });
  });

  group('the stickers used lately', () {
    test('go first, once, and are kept', () async {
      final store = await stickerStore(server);
      store.use(extra('noto', 'a'));
      store.use(extra('noto', 'b'));
      store.use(extra('fluent', 'a'));
      store.use(extra('noto', 'a'));
      expect(store.recent.map((s) => '${s.pack}/${s.sticker}'), ['noto/a', 'fluent/a', 'noto/b']);
      final later = await stickerStore(server);
      expect(later.recent.map((s) => '${s.pack}/${s.sticker}'), ['noto/a', 'fluent/a', 'noto/b']);
      expect(later.recent.first.emoji, '😀');
    });

    test('are thirty at most, the oldest dropped', () async {
      final store = await stickerStore(server);
      for (var i = 0; i < 40; i++) {
        store.use(extra('noto', 's$i'));
      }
      expect(store.recent, hasLength(30));
      expect(store.recent.first.sticker, 's39');
      expect(store.recent.last.sticker, 's10');
      expect((await stickerStore(server)).recent, hasLength(30));
    });

    test('are read from what is kept, whatever else is in it', () async {
      SharedPreferences.setMockInitialValues({
        'stickers.recent': [
          'not json',
          '{"k":"stk","p":"noto","s":"ok","e":"😀"}',
          '{"k":"stk","p":"../x","s":"ok","e":"x"}',
          '{"k":"stk"}',
        ],
      });
      final store = await stickerStore(server);
      expect(store.recent.map((s) => s.sticker), ['ok']);
    });
  });

  group('the pictures', () {
    test('are read from the disk before the server is asked', () async {
      final disk = MemoryStickerDisk()..files['noto/1f600.webp'] = Uint8List.fromList(List.filled(20, 7));
      final store = await stickerStore(server, disk: disk);
      expect(await store.image('noto', '1f600'), hasLength(20));
      expect(server.requests, isEmpty);
    });

    test('are fetched when they are not on the disk, and that one file is kept', () async {
      final disk = MemoryStickerDisk();
      final store = await stickerStore(server, disk: disk);
      expect(await store.image('extra', '1f389'), isNotNull);
      expect(disk.files.keys, ['extra/1f389.webp']);
      // The pack is not added, nor fetched
      expect(store.isAdded('extra'), isFalse);
      expect(server.imageRequests('extra'), 1);
      await store.image('extra', '1f389');
      expect(server.imageRequests('extra'), 1, reason: 'it is in memory now');
    });

    test('are fetched once for those who ask together', () async {
      final store = await stickerStore(server);
      final all = await Future.wait([for (var i = 0; i < 5; i++) store.image('noto', '1f600')]);
      expect(all.every((b) => b != null), isTrue);
      expect(server.imageRequests('noto'), 1);
    });

    test('are none when the server gives a web page for them, and not asked for again', () async {
      final store = await stickerStore(server);
      expect(await store.image('noto', 'gone'), isNull);
      expect(await store.image('nowhere', '1f600'), isNull);
      final asked = server.requests.length;
      expect(await store.image('noto', 'gone'), isNull);
      expect(server.requests, hasLength(asked));
    });

    test('are none when the server cannot be reached, and asked for again', () async {
      server.down = true;
      final store = await stickerStore(server);
      expect(await store.image('noto', '1f600'), isNull);
      server.down = false;
      expect(await store.image('noto', '1f600'), isNotNull);
    });

    test('are not asked for under a name that is no name', () async {
      final store = await stickerStore(server, disk: MemoryStickerDisk());
      expect(await store.image('..', '1f600'), isNull);
      expect(await store.image('noto', '../../x'), isNull);
      expect(server.requests, isEmpty);
    });
  });

  group('the folder of the disk', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('stickers-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps files by pack, and takes a pack off whole', () async {
      final disk = FolderStickerDisk(dir);
      expect(await disk.read('noto', 'a.webp'), isNull);
      await disk.write('noto', 'a.webp', Uint8List.fromList([1, 2, 3]));
      await disk.write('noto', 'complete.mark', Uint8List.fromList([1]));
      await disk.write('fluent', 'a.webp', Uint8List.fromList([4]));
      expect(await disk.read('noto', 'a.webp'), [1, 2, 3]);
      expect(File('${dir.path}/noto/a.webp.part').existsSync(), isFalse);
      await disk.deletePack('noto');
      expect(await disk.read('noto', 'a.webp'), isNull);
      expect(await disk.read('fluent', 'a.webp'), [4]);
    });

    test('goes nowhere outside its folder', () async {
      final disk = FolderStickerDisk(dir);
      await disk.write('..', 'a.webp', Uint8List.fromList([1]));
      await disk.write('noto', '../a.webp', Uint8List.fromList([1]));
      await disk.write('noto', '..', Uint8List.fromList([1]));
      expect(dir.parent.listSync().whereType<File>().where((f) => f.path.endsWith('a.webp')), isEmpty);
      expect(await disk.read('noto', '../a.webp'), isNull);
      await disk.deletePack('..');
      expect(dir.existsSync(), isTrue);
    });

    test('is what a store with a cache folder fetches into', () async {
      final store = await StickerStore.load(
        server: () => stickerServerAddress,
        cacheFolder: () async => dir.path,
        client: server.client,
      );
      await store.add('extra');
      expect(File('${dir.path}/stickers/extra/1f389.webp').existsSync(), isTrue);
      expect(File('${dir.path}/stickers/extra/complete.mark').existsSync(), isTrue);
      await store.remove('extra');
      expect(Directory('${dir.path}/stickers/extra').existsSync(), isFalse);
    });

    test('is not used without a cache folder: nothing is fetched', () async {
      final store = await StickerStore.load(
        server: () => stickerServerAddress,
        cacheFolder: () async => null,
        client: server.client,
      );
      await store.add('extra');
      expect(store.state('extra'), StickerPackState.ready);
      expect(server.imageRequests('extra'), 0);
    });
  });

  test('the credits of the art are among the licences the app shows', () async {
    registerStickerLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final noto = entries.where((e) => e.packages.contains('Noto Animated Emoji')).single;
    final fluent = entries.where((e) => e.packages.contains('Fluent Emoji')).single;
    final notoText = noto.paragraphs.map((p) => p.text).join('\n');
    final fluentText = fluent.paragraphs.map((p) => p.text).join('\n');
    expect(notoText, contains('CC BY 4.0'));
    expect(notoText, contains('Google'));
    expect(notoText, contains('https://creativecommons.org/licenses/by/4.0/'));
    expect(fluentText, contains('MIT License'));
    expect(fluentText, contains('Microsoft'));
    expect(fluentText, contains('Permission is hereby granted'));
  });
}
