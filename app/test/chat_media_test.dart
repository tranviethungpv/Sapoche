import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/chat_media.dart';
import 'package:sapoche/data/media_crypto.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';

import 'fake_backend.dart';

/// A picture with a gradient, so that it does not compress to nothing.
img.Image gradient(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p.r = p.x * 255 ~/ w;
    p.g = p.y * 255 ~/ h;
    p.b = (p.x + p.y) % 256;
  }
  return image;
}

/// A JPEG the way a camera writes it: [w] x [h] as stored, with an orientation and a place.
Uint8List cameraJpeg(int w, int h, {int orientation = 1}) {
  final image = gradient(w, h);
  image.exif.imageIfd.orientation = orientation;
  image.exif.gpsIfd.setGpsLocation(latitude: 21.03, longitude: 105.85);
  return img.encodeJpg(image, quality: 90);
}

/// The smallest GIF header a decoder reads the size from, followed by [pad] zeros.
Uint8List gifBytes(int pad) => Uint8List.fromList([
  ...ascii.encode('GIF89a'),
  0x20, 0x00, 0x10, 0x00, // 32 x 16
  ...List.filled(pad, 0),
]);

/// An extended WebP header that says it is animated and 300 x 200.
Uint8List animatedWebp() {
  final b = Uint8List(40);
  b.setAll(0, ascii.encode('RIFF'));
  b.setAll(8, ascii.encode('WEBPVP8X'));
  b[16] = 10;
  b[20] = 0x02;
  b[24] = (300 - 1) & 0xFF;
  b[25] = (300 - 1) >> 8;
  b[27] = (200 - 1) & 0xFF;
  return b;
}

Future<PreparedPhoto> made(int i, {int size = 100}) async {
  final bytes = Uint8List.fromList(List.generate(size, (k) => (k + i) % 256));
  return PreparedPhoto(
    name: 'p$i.jpg',
    bytes: bytes,
    mime: 'image/jpeg',
    w: 40 + i,
    h: 30,
    th: 'dGg$i',
    sealed: await MediaCrypto.seal(bytes),
  );
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('preparing a photo', () {
    test('turns it upright, drops what the camera wrote, and shrinks it to 1280 px', () async {
      // Stored 2000 x 1000 and to be shown turned a quarter: 1000 x 2000, so 640 x 1280 when sent
      final photo = await ChatMedia.prepareOne(PickedPhoto(cameraJpeg(2000, 1000, orientation: 6), 'IMG_1.jpg'));
      expect((photo.w, photo.h), (640, 1280));
      expect(photo.mime, 'image/jpeg');
      expect(photo.animated, isFalse);
      final sent = img.decodeJpg(photo.bytes)!;
      expect((sent.width, sent.height), (640, 1280));
      expect(sent.exif.isEmpty, isTrue, reason: 'no orientation, no place');
      expect(photo.bytes.length, lessThan(300 * 1024));
      expect(await MediaCrypto.open(photo.sealed.file, photo.sealed.key, sha: photo.sealed.sha), photo.bytes);
    });

    test('does not scale a small picture up', () async {
      final photo = await ChatMedia.prepareOne(PickedPhoto(cameraJpeg(100, 50), 'a.jpg'));
      expect((photo.w, photo.h), (100, 50));
    });

    test('a see-through PNG is put on white', () async {
      final image = img.Image(width: 20, height: 20, numChannels: 4);
      final photo = await ChatMedia.prepareOne(PickedPhoto(img.encodePng(image), 'a.png'));
      final pixel = img.decodeJpg(photo.bytes)!.getPixel(10, 10);
      expect(pixel.r, greaterThan(240));
      expect(pixel.g, greaterThan(240));
    });

    test('a thumbnail is a 24 px JPEG that is small', () async {
      final photo = await ChatMedia.prepareOne(PickedPhoto(cameraJpeg(800, 600), 'a.jpg'));
      final thumb = base64.decode(photo.th);
      final decoded = img.decodeJpg(thumb)!;
      expect((decoded.width, decoded.height), (24, 18));
      expect(photo.th.length, lessThan(1200));
      expect(photo.th, isNot(contains('data:')));
    });

    test('keeps a GIF as it is, and takes its size from the first frame', () async {
      final gif = img.encodeGif(gradient(48, 32));
      final photo = await ChatMedia.prepareOne(PickedPhoto(gif, 'fun.gif'));
      expect(photo.bytes, gif);
      expect(photo.mime, 'image/gif');
      expect(photo.animated, isTrue);
      expect((photo.w, photo.h), (48, 32));
      expect(photo.th, isNotEmpty);
    });

    test('goes by the first bytes, not by the name of the file', () async {
      final gif = img.encodeGif(gradient(8, 8));
      expect((await ChatMedia.prepareOne(PickedPhoto(gif, 'looks.jpg'))).mime, 'image/gif');
      final jpeg = await ChatMedia.prepareOne(PickedPhoto(cameraJpeg(30, 30), 'looks.gif'));
      expect(jpeg.mime, 'image/jpeg');
      expect(jpeg.bytes.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });

    test('keeps an animated WebP as it is, with the size the file says', () async {
      final webp = animatedWebp();
      final photo = await ChatMedia.prepareOne(PickedPhoto(webp, 'a.webp'));
      expect(photo.bytes, webp);
      expect(photo.mime, 'image/webp');
      expect((photo.w, photo.h), (300, 200));
    });

    test('refuses an animated picture of more than 3 MB, and says which', () async {
      await expectLater(
        ChatMedia.prepareOne(PickedPhoto(gifBytes(3 * 1024 * 1024), 'big.gif')),
        throwsA(isA<PhotoTooLarge>().having((e) => e.name, 'name', 'big.gif')),
      );
      // Exactly 3 MB is still taken
      final ok = gifBytes(3 * 1024 * 1024 - 10);
      expect(ok.length, 3 * 1024 * 1024);
      expect((await ChatMedia.prepareOne(PickedPhoto(ok, 'ok.gif'))).mime, 'image/gif');
    });

    test('bytes that are no picture are refused', () async {
      await expectLater(
        ChatMedia.prepareOne(PickedPhoto(Uint8List.fromList(List.filled(100, 7)), 'x.jpg')),
        throwsA(isA<PhotoUnreadable>()),
      );
    });

    test('a batch keeps the order, leaves out what is refused, and holds ten at most', () async {
      final result = await ChatMedia.prepare([
        PickedPhoto(cameraJpeg(30, 20), 'one.jpg'),
        PickedPhoto(gifBytes(3 * 1024 * 1024), 'big.gif'),
        PickedPhoto(cameraJpeg(20, 30), 'two.jpg'),
      ]);
      expect(result.photos.map((p) => p.name), ['one.jpg', 'two.jpg']);
      expect(result.refused.single, isA<PhotoTooLarge>());

      final many = await ChatMedia.prepare([
        for (var i = 0; i < 12; i++) PickedPhoto(cameraJpeg(10, 10 + i), 'p$i.jpg'),
      ]);
      expect(many.photos, hasLength(AlbumExtra.maxItems));
      expect(many.photos.last.name, 'p9.jpg');
    });
  });

  group('putting pictures up', () {
    late FakeBackend backend;
    late ChatMedia media;

    setUp(() {
      backend = FakeBackend();
      media = ChatMedia(backend);
    });

    test('asks for the tickets once, puts every file up three at a time, and gives the album', () async {
      final photos = [for (var i = 0; i < 7; i++) await made(i, size: 100 + i)];
      var running = 0, most = 0;
      backend.onUpload = (_) async {
        most = max(most, ++running);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return true;
      };
      final progress = <(int, int)>[];
      final upload = media.upload(photos, caption: 'trip');
      final outcome = await upload.upload(onProgress: (d, t) => progress.add((d, t)));

      expect(backend.calls.where((c) => c.startsWith('mediaTickets')), [
        'mediaTickets ${photos.map((p) => p.sealed.file.length).join(',')}',
      ]);
      expect(backend.uploaded, hasLength(7));
      expect(most, 3);
      expect(progress.last, (7, 7));
      expect(progress.map((p) => p.$1), [1, 2, 3, 4, 5, 6, 7]);
      expect(upload.states, everyElement(FileState.done));
      expect(upload.error, isNull);

      final album = outcome.album!;
      expect(album.caption, 'trip');
      expect(album.items.map((i) => i.m), [for (var i = 0; i < 7; i++) 'file${'$i'.padLeft(17, '0')}']);
      final first = album.items.first;
      expect(first.key, photos.first.sealed.key);
      expect(first.sha, photos.first.sealed.sha);
      expect(first.n, photos.first.sealed.file.length);
      expect((first.mime, first.w, first.h, first.th), ('image/jpeg', 40, 30, 'dGg0'));
      expect(backend.uploaded[first.m], photos.first.sealed.file);
      expect(AlbumExtra.fromJson(album.toJson()).items, hasLength(7));
    });

    test('puts what it uploaded in the cache, so it is never downloaded', () async {
      final photos = [await made(0)];
      final album = (await media.upload(photos).upload()).album!;
      expect(await media.open('ABC234', album.items.single), photos.single.bytes);
      expect(backend.calls, isNot(contains(startsWith('downloadMedia'))));
    });

    test('a file that fails can be tried again, on the same tickets, and the others are not sent twice', () async {
      final photos = [for (var i = 0; i < 4; i++) await made(i)];
      var broken = true;
      backend.onUpload = (t) async => !(broken && t.token == 'tok2');
      final upload = media.upload(photos);
      final first = await upload.upload();
      expect(first.album, isNull);
      expect(first.error, AlbumUpload.fileFailed);
      expect(upload.error, AlbumUpload.fileFailed);
      expect(upload.states, [FileState.done, FileState.done, FileState.failed, FileState.done]);
      expect(upload.done, 3);

      broken = false;
      backend.calls.clear();
      final second = await upload.retryFailed();
      expect(second.album!.items, hasLength(4));
      expect(backend.calls, ['uploadMedia file00000000000000002']);
      expect(upload.states, everyElement(FileState.done));
      expect(upload.error, isNull);
    });

    test('tickets older than their life are asked for again, for the failed files only', () async {
      final photos = [for (var i = 0; i < 3; i++) await made(i)];
      var minted = 0;
      backend.ticketsFor = (sizes) => MediaTickets.granted([
        for (final n in sizes)
          MediaTicket(m: 'media${'${minted++}'.padLeft(15, '0')}', url: '/media/ABC234/x?n=$n', token: 't'),
      ]);
      var broken = true;
      backend.onUpload = (t) async => !(broken && t.m.endsWith('1'));
      var now = DateTime(2026, 11, 2, 10);
      final upload = media.upload(photos)..clock = () => now;
      await upload.upload();
      expect(upload.states, [FileState.done, FileState.failed, FileState.done]);

      broken = false;
      now = now.add(const Duration(minutes: 10));
      backend.calls.clear();
      final outcome = await upload.retryFailed();
      expect(backend.calls.first, 'mediaTickets ${photos[1].sealed.file.length}');
      expect(outcome.album!.items.map((i) => i.m), [
        'media000000000000000',
        'media000000000000003',
        'media000000000000002',
      ]);
    });

    test('a retry soon after reuses the tickets', () async {
      final photos = [for (var i = 0; i < 2; i++) await made(i)];
      var broken = true;
      backend.onUpload = (t) async => !(broken && t.token == 'tok0');
      final upload = media.upload(photos);
      await upload.upload();
      broken = false;
      await upload.retryFailed();
      expect(backend.calls.where((c) => c.startsWith('mediaTickets')), hasLength(1));
    });

    test('a refusal is told by its code, and nothing is put up', () async {
      backend.ticketsFor = (_) => const MediaTickets.refused('media_full');
      final upload = media.upload([await made(0), await made(1)]);
      final outcome = await upload.upload();
      expect(outcome.album, isNull);
      expect(outcome.error, 'media_full');
      expect(upload.error, 'media_full');
      expect(upload.states, everyElement(FileState.waiting));
      expect(backend.uploaded, isEmpty);
    });

    test('a room that answers with the wrong number of tickets is not trusted', () async {
      backend.ticketsFor = (_) => const MediaTickets.granted([]);
      final outcome = await media.upload([await made(0)]).upload();
      expect(outcome.error, 'media_unavailable');
    });

    test('no answer at all is offline', () async {
      backend.failWith = StateError('gone');
      final outcome = await media.upload([await made(0)]).upload();
      expect(outcome.error, 'offline');
    });

    test('a released album sends nothing more', () async {
      final upload = media.upload([await made(0), await made(1), await made(2), await made(3)]);
      backend.onUpload = (_) async {
        upload.release();
        return true;
      };
      final outcome = await upload.upload();
      expect(outcome.album, isNull);
      expect(upload.released, isTrue);
      expect(backend.calls.where((c) => c.startsWith('uploadMedia')).length, lessThanOrEqualTo(3));
    });
  });

  group('opening a picture', () {
    late FakeBackend backend;
    late ChatMedia media;

    setUp(() {
      backend = FakeBackend();
      media = ChatMedia(backend);
    });

    /// A picture of the room as the bucket holds it, and the album item that points at it.
    Future<AlbumItem> inBucket(String m, List<int> bytes) async {
      final sealed = await MediaCrypto.seal(bytes);
      backend.mediaFiles[m] = sealed.file;
      return AlbumItem(
        m: m,
        key: sealed.key,
        sha: sealed.sha,
        mime: 'image/jpeg',
        w: 1,
        h: 1,
        n: sealed.file.length,
        th: '',
      );
    }

    test('fetches, checks and decrypts it, and has it the second time', () async {
      final item = await inBucket('aaa', [1, 2, 3, 4, 5]);
      expect(await media.open('ABC234', item), [1, 2, 3, 4, 5]);
      expect(await media.open('ABC234', item), [1, 2, 3, 4, 5]);
      expect(backend.calls.where((c) => c.startsWith('downloadMedia')), ['downloadMedia aaa']);
    });

    test('is null when it is not there, does not check out, or is not sealed with the key', () async {
      final item = await inBucket('bbb', [9, 9, 9]);
      expect(
        await media.open(
          'ABC234',
          AlbumItem(m: 'nope', key: item.key, sha: item.sha, mime: 'image/jpeg', w: 1, h: 1, n: 1, th: ''),
        ),
        isNull,
      );

      final wrongSha = AlbumItem(m: 'bbb', key: item.key, sha: 'AAAA', mime: 'image/jpeg', w: 1, h: 1, n: 1, th: '');
      expect(await media.open('ABC234', wrongSha), isNull);

      final other = await MediaCrypto.seal([1]);
      final wrongKey = AlbumItem(m: 'bbb', key: other.key, sha: item.sha, mime: 'image/jpeg', w: 1, h: 1, n: 1, th: '');
      expect(await media.open('ABC234', wrongKey), isNull);

      // What did not check out is not kept: the right item still opens
      expect(await media.open('ABC234', item), [9, 9, 9]);
    });

    test('a file the bucket changed is not opened', () async {
      final item = await inBucket('ccc', [1, 2, 3]);
      final touched = Uint8List.fromList(backend.mediaFiles['ccc']!)..[14] ^= 1;
      backend.mediaFiles['ccc'] = touched;
      expect(await media.open('ABC234', item), isNull);
    });

    test('a failing fetch is null', () async {
      final item = await inBucket('ddd', [1]);
      backend.failWith = StateError('offline');
      expect(await media.open('ABC234', item), isNull);
    });

    test('callers asking for the same picture share one fetch', () async {
      final item = await inBucket('eee', [7, 7]);
      final gate = Completer<void>();
      backend.onDownload = (_) => gate.future;
      final all = [for (var i = 0; i < 5; i++) media.open('ABC234', item)];
      await settle();
      gate.complete();
      for (final bytes in await Future.wait(all)) {
        expect(bytes, [7, 7]);
      }
      expect(backend.calls.where((c) => c.startsWith('downloadMedia')), hasLength(1));
    });

    test('keeps the latest 24 in memory', () async {
      final items = [
        for (var i = 0; i < 25; i++) await inBucket('m$i', [i]),
      ];
      for (final item in items) {
        await media.open('ABC234', item);
      }
      backend.calls.clear();
      await media.open('ABC234', items.last);
      expect(backend.calls, isEmpty);
      await media.open('ABC234', items.first);
      expect(backend.calls, ['downloadMedia m0']);
    });

    test('keeps the decrypted file in the cache folder, where a new start finds it', () async {
      final folder = Directory.systemTemp.createTempSync('chat-media-test');
      addTearDown(() => folder.deleteSync(recursive: true));
      backend.cacheDir = folder.path;
      final item = await inBucket('fff', [4, 5, 6]);
      expect(await media.open('ABC234', item), [4, 5, 6]);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final file = File('${folder.path}/chat-media/fff');
      expect(file.readAsBytesSync(), [4, 5, 6]);

      backend.calls.clear();
      final later = ChatMedia(backend);
      expect(await later.open('ABC234', item), [4, 5, 6]);
      expect(backend.calls, isNot(contains(startsWith('downloadMedia'))));
    });
  });

  group('sending an album from the controller', () {
    late FakeBackend backend;
    late RoomController controller;

    setUp(() async {
      backend = FakeBackend();
      controller = RoomController(backend);
      await controller.start();
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(const ChatEvent(room: 'ABC234', messages: [], replace: true));
      await settle();
    });

    tearDown(() => controller.dispose());

    ChatMessage theirs(String text, String? cid, Map<String, dynamic>? x) =>
        ChatMessage(id: 1, by: 'me', name: 'Anna', text: text, at: 1790660600000, cid: cid, x: x);

    test('shows it at once, puts the pictures up, sends it, and lets go when the room confirms', () async {
      final photos = [await made(0), await made(1)];
      final gate = Completer<void>();
      backend.onUpload = (_) async {
        await gate.future;
        return true;
      };
      final sending = controller.sendAlbum(photos);
      await settle();

      final pending = controller.chat.value.single;
      expect(pending.delivery, ChatDelivery.sending);
      expect(pending.text, '📷 2 photos');
      expect(controller.albumUploads.value[pending.cid]!.photos, photos);
      expect(backend.calls, isNot(contains(startsWith('sendChat'))));

      gate.complete();
      await sending;
      expect(backend.calls, contains('sendChat 📷 2 photos'));
      final extra = backend.lastExtra!;
      expect(extra['k'], 'album');
      expect(AlbumExtra.fromJson(extra).items, hasLength(2));
      expect(backend.lastChatCid, pending.cid);
      expect(controller.chat.value.single.delivery, ChatDelivery.sending);

      backend.emit(ChatEvent(room: 'ABC234', messages: [theirs('📷 2 photos', pending.cid, extra)], replace: false));
      await settle();
      final shown = controller.chat.value.single;
      expect(shown.delivery, ChatDelivery.sent);
      expect(ChatExtra.of(shown), isA<AlbumExtra>());
      expect(controller.albumUploads.value, isEmpty);
    });

    test('words are the stand-in for one picture, with the caption after it', () async {
      await controller.sendAlbum([await made(0)]);
      expect(controller.chat.value.single.text, '📷 Photo');
      expect(AlbumExtra.fromJson(backend.lastExtra!).caption, isNull);

      S.current = 'vi';
      addTearDown(() => S.current = 'en');
      await controller.sendAlbum([await made(0), await made(1)], caption: '  Hạ Long ');
      expect(controller.chat.value.last.text, '📷 2 ảnh Hạ Long');
      expect(AlbumExtra.fromJson(backend.lastExtra!).caption, 'Hạ Long');
    });

    test('a room out of space shows the message as not sent, and says why', () async {
      backend.ticketsFor = (_) => const MediaTickets.refused('media_full');
      await controller.sendAlbum([await made(0)]);
      final failed = controller.chat.value.single;
      expect(failed.delivery, ChatDelivery.failed);
      expect(controller.albumUploads.value[failed.cid]!.error, 'media_full');
      expect(backend.calls, isNot(contains(startsWith('sendChat'))));

      // The room has space again
      backend.ticketsFor = null;
      await controller.resendChat(failed);
      expect(controller.chat.value.single.cid, failed.cid);
      expect(backend.lastExtra!['k'], 'album');
      expect(controller.albumUploads.value[failed.cid]!.error, isNull);
    });

    test('a file that does not go up fails the message, and the retry puts up only that file', () async {
      var broken = true;
      backend.onUpload = (t) async => !(broken && t.token == 'tok1');
      await controller.sendAlbum([await made(0), await made(1)]);
      final failed = controller.chat.value.single;
      expect(failed.delivery, ChatDelivery.failed);
      expect(controller.albumUploads.value[failed.cid]!.states, [FileState.done, FileState.failed]);

      broken = false;
      backend.calls.clear();
      await controller.resendChat(failed);
      expect(backend.calls.where((c) => c.startsWith('uploadMedia')), hasLength(1));
      expect(backend.lastExtra!['k'], 'album');
    });

    test('a message the room did not take after the pictures were up is sent again without them', () async {
      backend.chatConnected = false;
      await controller.sendAlbum([await made(0)]);
      final failed = controller.chat.value.single;
      expect(failed.delivery, ChatDelivery.failed);
      expect(backend.uploaded, hasLength(1));

      backend.chatConnected = true;
      backend.calls.clear();
      await controller.resendChat(failed);
      expect(backend.calls, ['sendChat 📷 Photo']);
      expect(backend.lastExtra!['k'], 'album');
    });

    test('dropping the message lets go of the pictures, and what is still going up is not sent', () async {
      final gate = Completer<void>();
      backend.onUpload = (_) async {
        await gate.future;
        return true;
      };
      final sending = controller.sendAlbum([await made(0)]);
      await settle();
      final pending = controller.chat.value.single;
      final upload = controller.albumUploads.value[pending.cid]!;
      controller.discardChat(pending);
      expect(controller.chat.value, isEmpty);
      expect(controller.albumUploads.value, isEmpty);
      expect(upload.released, isTrue);

      gate.complete();
      await sending;
      expect(backend.calls, isNot(contains(startsWith('sendChat'))));
      expect(controller.chat.value, isEmpty);
    });

    test('pictures that are gone from memory cannot be sent again: the message goes', () async {
      backend.ticketsFor = (_) => const MediaTickets.refused('media_limit');
      await controller.sendAlbum([await made(0)]);
      final failed = controller.chat.value.single;
      controller.albumUploads.value[failed.cid]!.release();
      await controller.resendChat(failed);
      expect(controller.chat.value, isEmpty);
      expect(controller.albumUploads.value, isEmpty);
    });

    test('leaving the room lets go of every album', () async {
      backend.ticketsFor = (_) => const MediaTickets.refused('media_full');
      await controller.sendAlbum([await made(0)]);
      final upload = controller.albumUploads.value.values.single;
      backend.emit(StateEvent(sampleRoom(local: true)));
      await settle();
      expect(upload.released, isTrue);
      expect(controller.albumUploads.value, isEmpty);
    });

    test('a text message is sent as before', () async {
      await controller.sendChat('hello');
      expect(backend.calls, contains('sendChat hello'));
      expect(backend.lastExtra, isNull);
      expect(controller.albumUploads.value, isEmpty);
      final failed = controller.chat.value.single.withDelivery(ChatDelivery.failed);
      await controller.resendChat(failed);
      expect(backend.calls.where((c) => c == 'sendChat hello'), hasLength(2));
    });

    test('nothing is sent where the room has no chat', () async {
      backend.emit(StateEvent(sampleRoom(local: true)));
      await settle();
      await controller.sendAlbum([await made(0)]);
      expect(controller.chat.value, isEmpty);
      expect(backend.calls, isNot(contains(startsWith('mediaTickets'))));
    });
  });
}
