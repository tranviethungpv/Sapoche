import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/chat_media.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';

import 'chat_photos_test.dart' as photos;
import 'fake_backend.dart';
import 'png_fixture.dart';

const path = '/phone/DCIM/clip.mov';

AlbumItem videoItem({int d = 31000}) => const AlbumItem(
  m: 'vidaaaaaaaaaaaaaaaaaa',
  key: 'k',
  sha: 's',
  mime: 'video/mp4',
  w: 720,
  h: 1280,
  n: 5000,
  th: '',
  d: 31000,
);

/// A player that plays nothing but says it is ready, so that the page of a video can be laid out.
class _FakePlayer extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 21),
      size: const Size(1080, 2340),
    ),
  );

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.green);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Colors.green);

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => const Duration(seconds: 3);

  @override
  Future<void> dispose(int playerId) async {}
}

void main() {
  group('a video in an album message', () {
    Map<String, dynamic> json(List<Map<String, Object?>> items) => {'k': 'album', 'items': items};
    Map<String, Object?> item(String mime, {int? d}) => {
      'm': 'a',
      'key': 'k',
      'sha': 's',
      'mime': mime,
      'w': 4,
      'h': 3,
      'n': 9,
      'th': '',
      'd': ?d,
    };

    test('is a video and its poster, and says how long it is', () {
      final album = AlbumExtra.fromJson(json([item('video/mp4', d: 31000), item('image/jpeg')]));
      expect(album.isVideo, isTrue);
      expect(album.video.d, 31000);
      expect(album.poster.mime, 'image/jpeg');
      expect(album.video.animated, isFalse);
      expect(AlbumExtra.fromJson(album.toJson().cast<String, dynamic>()).video.d, 31000);
    });

    test('a picture album has no length in it', () {
      final album = AlbumExtra.fromJson(json([item('image/jpeg'), item('image/gif')]));
      expect(album.isVideo, isFalse);
      expect((album.toJson()['items']! as List).first, isNot(contains('d')));
    });

    test('a video that is not exactly a video and a poster is refused', () {
      expect(() => AlbumExtra.fromJson(json([item('video/mp4', d: 5)])), throwsFormatException);
      expect(
        () => AlbumExtra.fromJson(json([item('video/mp4', d: 5), item('image/jpeg'), item('image/jpeg')])),
        throwsFormatException,
      );
      expect(
        () => AlbumExtra.fromJson(json([item('video/mp4', d: 5), item('video/mp4', d: 5)])),
        throwsFormatException,
      );
    });
  });

  group('sending a video', () {
    late File made;

    Future<(FakeBackend, RoomController)> chatWith(
      WidgetTester tester, {
      Object? answer,
      Future<PickedVideo?> Function(PhotoSource)? picker,
      ChatPhotoPickerAlias? photoPicker,
    }) async {
      made = File('${Directory.systemTemp.path}/sapoche_video_test_${DateTime.now().microsecondsSinceEpoch}.mp4');
      await tester.runAsync(() => made.writeAsBytes(List.filled(5000, 7)));
      addTearDown(() => made.existsSync() ? made.deleteSync() : null);
      final (backend, room) = await photos.openChat(
        tester,
        (backend, room) async => [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hi', at: 1790660600000)],
        picker: photoPicker,
        videoPicker: picker ?? (_) async => const PickedVideo(path: path, name: 'clip.mov'),
      );
      backend.videos[path] =
          answer ?? VideoFile(path: made.path, w: 720, h: 1280, durMs: 31000, poster: solidPng(30, 120, 60, side: 24));
      return (backend, room);
    }

    Future<void> pickVideo(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-source-gallery')));
      await tester.pump();
      await tester.pump();
    }

    Future<void> waitFor(WidgetTester tester, Finder finder) =>
        photos.until(tester, () => finder.evaluate().isNotEmpty).then((_) => tester.pumpAndSettle());

    testWidgets('the source sheet offers videos beside photos', (tester) async {
      await chatWith(tester);
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      expect(find.text(S.videoGallery), findsOneWidget);
      expect(find.text(S.videoRecord), findsOneWidget);
    });

    testWidgets('a picked video is squeezed, shown above the field with its length and size, and can be taken out', (
      tester,
    ) async {
      final (backend, _) = await chatWith(tester);
      await pickVideo(tester);
      expect(find.byKey(const ValueKey('chat-photo-preparing')), findsOneWidget);
      await waitFor(tester, find.byKey(const ValueKey('staged-video-info')));
      expect(backend.calls, contains('prepareVideo $path'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('staged-video-info'))).data, startsWith('0:31 · 0.0 MB'));
      await tester.tap(find.byKey(const ValueKey('video-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('staged-photos')), findsNothing);
    });

    testWidgets('Send puts the video and its poster up as one message, with the caption', (tester) async {
      final (backend, room) = await chatWith(tester);
      await pickVideo(tester);
      await waitFor(tester, find.byKey(const ValueKey('staged-video-info')));
      await tester.enterText(find.byKey(const ValueKey('chat-field')), 'look');
      await photos.pressSend(tester);

      expect(backend.calls, contains('sendChat ${S.chatVideoText} look'));
      final album = AlbumExtra.fromJson(backend.lastExtra!);
      expect(album.isVideo, isTrue);
      expect(album.video.d, 31000);
      expect(album.video.mime, 'video/mp4');
      expect(album.poster.mime, 'image/jpeg');
      expect(album.caption, 'look');
      expect(room.chat.value.last.delivery, ChatDelivery.sending);
      // In the chat as its poster alone, with its length, and no count of files
      expect(find.byKey(const ValueKey('photo-single')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-duration')), findsOneWidget);
      expect(find.text('1/2'), findsNothing);
      await photos.endWait(tester);
    });

    testWidgets('video and photos do not go in one message', (tester) async {
      final (backend, _) = await chatWith(
        tester,
        photoPicker: (_) async => [PickedPhoto(solidPng(30, 120, 60, side: 12), 'a.png')],
      );
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pump();
      await photos.stagedShown(tester);
      await pickVideo(tester);
      await tester.pumpAndSettle();
      expect(find.text(S.chatNoMix), findsOneWidget);
      expect(backend.calls.where((c) => c.startsWith('prepareVideo')), isEmpty);
    });

    testWidgets('a video too long to squeeze under 10 MB is told, and nothing waits', (tester) async {
      await chatWith(tester, answer: BackendException('video_too_big', 'long'));
      await pickVideo(tester);
      await photos.until(tester, () => find.text(S.chatVideoTooLarge('clip.mov', true)).evaluate().isNotEmpty);
      await tester.pump();
      expect(find.text(S.chatVideoTooLarge('clip.mov', true)), findsOneWidget);
      expect(find.byKey(const ValueKey('staged-photos')), findsNothing);
    });

    testWidgets('a video the phone cannot read is told', (tester) async {
      await chatWith(tester, answer: BackendException('video_unreadable', 'no'));
      await pickVideo(tester);
      await photos.until(tester, () => find.text(S.chatVideoUnreadable('clip.mov')).evaluate().isNotEmpty);
      await tester.pump();
      expect(find.text(S.chatVideoUnreadable('clip.mov')), findsOneWidget);
    });

    testWidgets('backing out of the picker does nothing', (tester) async {
      final (backend, _) = await chatWith(tester, picker: (_) async => null);
      await pickVideo(tester);
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('prepareVideo')), isEmpty);
      expect(find.byKey(const ValueKey('staged-photos')), findsNothing);
    });
  });

  group('turning a selfie left to right', () {
    /// Red on the left, blue on the right, as a JPEG.
    Uint8List twoColours() {
      final image = img.Image(width: 64, height: 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 64; x++) {
          image.setPixelRgb(x, y, x < 32 ? 220 : 20, 20, x < 32 ? 20 : 220);
        }
      }
      return img.encodeJpg(image, quality: 95);
    }

    (bool, bool) leftIsRed(Uint8List bytes) {
      final image = img.decodeImage(bytes)!;
      final left = image.getPixel(image.width ~/ 4, image.height ~/ 2);
      final right = image.getPixel(image.width * 3 ~/ 4, image.height ~/ 2);
      return (left.r > left.b, right.b > right.r);
    }

    testWidgets('a photo is turned: what was on the left is on the right', (tester) async {
      final made = (await tester.runAsync(() => ChatMedia.prepareOne(PickedPhoto(twoColours(), 'selfie.jpg'))))!;
      expect(leftIsRed(made.bytes), (true, true));
      final turned = (await tester.runAsync(() => ChatMedia.mirror(made)))!;
      expect(leftIsRed(turned.bytes), (false, false));
      // And back again
      final back = (await tester.runAsync(() => ChatMedia.mirror(turned)))!;
      expect(leftIsRed(back.bytes), (true, true));
      expect(turned.sealed.key, isNot(made.sealed.key), reason: 'a new picture is sealed anew');
    });

    testWidgets('a picture that moves is not turned', (tester) async {
      final gif = img.encodeGif(img.Image(width: 20, height: 10));
      final made = (await tester.runAsync(() => ChatMedia.prepareOne(PickedPhoto(gif, 'fun.gif'))))!;
      expect((await tester.runAsync(() => ChatMedia.mirror(made)))!.bytes, made.bytes);
    });

    testWidgets('the button on a waiting photo turns it where it is', (tester) async {
      final (_, room) = await photos.openChat(
        tester,
        (backend, room) async => [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hi', at: 1790660600000)],
        picker: (_) async => [PickedPhoto(twoColours(), 'selfie.jpg')],
      );
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pump();
      await photos.stagedShown(tester);
      await tester.tap(find.byKey(const ValueKey('photo-flip-0')));
      await tester.pump();
      await photos.until(tester, () => find.byKey(const ValueKey('chat-photo-preparing')).evaluate().isEmpty);
      await tester.pumpAndSettle();
      await photos.pressSend(tester);
      final sent = room.albumUploads.value.values.single.photos.single;
      expect(leftIsRed(sent.bytes), (false, false));
      await photos.endWait(tester);
    });

    testWidgets('a waiting video is made again turned, and again to turn it back', (tester) async {
      final made = File('${Directory.systemTemp.path}/sapoche_flip_${DateTime.now().microsecondsSinceEpoch}.mp4');
      await tester.runAsync(() => made.writeAsBytes(List.filled(2000, 5)));
      addTearDown(() => made.existsSync() ? made.deleteSync() : null);
      final (backend, _) = await photos.openChat(
        tester,
        (backend, room) async => [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hi', at: 1790660600000)],
        videoPicker: (_) async => const PickedVideo(path: path, name: 'clip.mov'),
      );
      backend.videos[path] = VideoFile(
        path: made.path,
        w: 720,
        h: 1280,
        durMs: 5000,
        poster: solidPng(30, 120, 60, side: 24),
      );
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-source-gallery')));
      await tester.pump();
      await photos.until(tester, () => find.byKey(const ValueKey('staged-video-info')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c == 'prepareVideo $path'), hasLength(1));

      // Made again by native, which is given the file again and the turn; the file was given back (and deleted) once
      await tester.runAsync(() => made.writeAsBytes(List.filled(2000, 5)));
      await tester.tap(find.byKey(const ValueKey('video-flip')));
      await tester.pump();
      await photos.until(tester, () => backend.calls.contains('prepareVideo $path mirror'));
      await photos.until(tester, () => find.byKey(const ValueKey('chat-photo-preparing')).evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(find.text(S.chatNoMix), findsNothing);
      expect(find.byKey(const ValueKey('staged-video-info')), findsOneWidget);

      await tester.runAsync(() => made.writeAsBytes(List.filled(2000, 5)));
      await tester.tap(find.byKey(const ValueKey('video-flip')));
      await tester.pump();
      await photos.until(tester, () => backend.calls.where((c) => c == 'prepareVideo $path').length == 2);
      await photos.until(tester, () => find.byKey(const ValueKey('chat-photo-preparing')).evaluate().isEmpty);
      expect(backend.calls.where((c) => c == 'prepareVideo $path'), hasLength(2));
      await tester.pumpAndSettle();
    });
  });

  group('a video received', () {
    Future<(FakeBackend, RoomController)> chatWithVideo(WidgetTester tester) => photos.openChat(tester, (
      backend,
      room,
    ) async {
      final poster = await photos.prepared(tester, 1);
      backend.mediaFiles['postaaaaaaaaaaaaaaaaaa'] = poster.sealed.file;
      room.media.remember('postaaaaaaaaaaaaaaaaaa', poster.bytes);
      final video = await photos.prepared(tester, 2);
      backend.mediaFiles['vidaaaaaaaaaaaaaaaaaa'] = video.sealed.file;
      room.media.remember('vidaaaaaaaaaaaaaaaaaa', video.bytes);
      final album = AlbumExtra(
        items: [
          videoItem(),
          AlbumItem(
            m: 'postaaaaaaaaaaaaaaaaaa',
            key: poster.sealed.key,
            sha: poster.sealed.sha,
            mime: 'image/jpeg',
            w: 720,
            h: 1280,
            n: poster.sealed.file.length,
            th: poster.th,
          ),
        ],
        caption: 'party',
      );
      return [ChatMessage(id: 1, by: 'b', name: 'Binh', text: S.chatVideoText, at: 1790660600000, x: album.toJson())];
    });

    testWidgets('is its poster with a play mark and its length, not a stack, and the caption under it', (tester) async {
      await chatWithVideo(tester);
      expect(find.byKey(const ValueKey('photo-single')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-stack')), findsNothing);
      expect(find.byKey(const ValueKey('video-play-mark')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('video-duration'))).data, '0:31');
      expect(find.text('party'), findsOneWidget);
    });

    testWidgets('a touch opens the page that plays it, with the poster meanwhile', (tester) async {
      await chatWithVideo(tester);
      await tester.tap(find.byKey(const ValueKey('photo-single')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('video-page')), findsOneWidget);
      // No player in a test: it says so rather than hang
      await photos.until(tester, () => find.byKey(const ValueKey('video-failed')).evaluate().isNotEmpty);
      await tester.pump();
      expect(find.byKey(const ValueKey('video-failed')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-page')), findsNothing);
    });

    testWidgets('the controls of the page are at its foot, under the picture and not over it', (tester) async {
      VideoPlayerPlatform.instance = _FakePlayer();
      await chatWithVideo(tester);
      await tester.tap(find.byKey(const ValueKey('photo-single')));
      await tester.pump();
      await photos.until(tester, () => find.byKey(const ValueKey('video-seek')).evaluate().isNotEmpty);
      await tester.pump();
      final page = tester.getRect(find.byKey(const ValueKey('video-page')));
      final seek = tester.getRect(find.byKey(const ValueKey('video-seek')));
      expect(seek.bottom, greaterThan(page.bottom - 120), reason: 'the bar is at the foot of the screen');
      // And under the picture, not over it
      expect(tester.getRect(find.byKey(const ValueKey('video-surface'))).bottom, lessThanOrEqualTo(seek.top));
      expect(find.byKey(const ValueKey('video-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-save')), findsOneWidget);
      // White on the black page, whatever the theme of the app: dark buttons would not be seen
      for (final key in ['video-play', 'video-save', 'video-close']) {
        final button = tester.widget<IconButton>(find.byKey(ValueKey(key)));
        final style = button.style ?? IconButtonTheme.of(tester.element(find.byKey(ValueKey(key)))).style;
        expect(style?.foregroundColor?.resolve({}), Colors.white, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('video-close')));
      await tester.pumpAndSettle();
    });

    testWidgets('the menu of the message saves the video, not pictures', (tester) async {
      await chatWithVideo(tester);
      await tester.longPress(find.byKey(const ValueKey('photo-single')));
      await tester.pumpAndSettle();
      expect(find.text(S.videoSave), findsOneWidget);
      expect(find.text(S.photoSaveAll), findsNothing);
    });
  });
}

typedef ChatPhotoPickerAlias = ChatPhotoPicker;
