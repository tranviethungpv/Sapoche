import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/chat_media.dart';
import 'package:sapoche/data/media_crypto.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/data/photo_save.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';

import 'fake_backend.dart';
import 'png_fixture.dart';
import 'pump_app.dart';

/// A photo ready to go, real enough to be drawn: a small PNG, sealed.
Future<PreparedPhoto> prepared(WidgetTester tester, int i) async {
  final bytes = solidPng(40 * i % 255, 90, 160, side: 8);
  final sealed = (await tester.runAsync(() => MediaCrypto.seal(bytes)))!;
  return PreparedPhoto(
    name: 'p$i.png',
    bytes: bytes,
    mime: 'image/jpeg',
    w: 4,
    h: 3,
    th: base64.encode(bytes),
    sealed: sealed,
  );
}

/// An album of [n] pictures whose files the room holds (encrypted), and, with [keep], this device has already opened.
Future<AlbumExtra> makeAlbum(
  WidgetTester tester,
  FakeBackend backend,
  RoomController room,
  int n, {
  Set<int> gifs = const {},
  String? caption,
  bool keep = true,
  int w = 400,
  int h = 300,
}) async {
  final items = <AlbumItem>[];
  for (var i = 0; i < n; i++) {
    final photo = await prepared(tester, i);
    final m = 'pic${i}aaaaaaaaaaaaaaaaa';
    backend.mediaFiles[m] = photo.sealed.file;
    if (keep) room.media.remember(m, photo.bytes);
    items.add(
      AlbumItem(
        m: m,
        key: photo.sealed.key,
        sha: photo.sealed.sha,
        mime: gifs.contains(i) ? 'image/gif' : 'image/jpeg',
        w: w,
        h: h,
        n: photo.sealed.file.length,
        th: photo.th,
      ),
    );
  }
  return AlbumExtra(items: items, caption: caption);
}

ChatMessage albumMessage(int id, AlbumExtra extra, {String by = 'b', int? at, String? cid}) => ChatMessage(
  id: id,
  by: by,
  name: by == 'me' ? 'Anna' : 'Binh',
  text: S.chatPhotoText(extra.items.length),
  at: at ?? 1790660600000 + id * 1000,
  cid: cid,
  x: extra.toJson(),
);

ChatEvent history(List<ChatMessage> messages) => ChatEvent(room: 'ABC234', messages: messages, replace: true);

ChatEvent arrived(ChatMessage m) => ChatEvent(room: 'ABC234', messages: [m], replace: false);

/// Lets real asynchronous work (isolates) finish until [done].
Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'work away from the screen did not finish');
}

/// Waits for the picked photos to be made ready, and for the preview to be up.
Future<void> previewShown(WidgetTester tester) async {
  await until(tester, () => find.byKey(const ValueKey('photo-preview-count')).evaluate().isNotEmpty);
  await tester.pumpAndSettle();
}

/// A message sent waits for the room to confirm it: lets that wait run out, as a test that sends one has to.
Future<void> endWait(WidgetTester tester) => tester.pump(RoomController.chatDeliveryTimeout * 2);

/// The app in a room with a chat, which holds [messages]; the chat is open.
Future<(FakeBackend, RoomController)> openChat(
  WidgetTester tester,
  Future<List<ChatMessage>> Function(FakeBackend, RoomController) messages, {
  ChatPhotoPicker? picker,
  PhotoSaver? saver,
}) async {
  final (backend, room) = await pumpApp(tester, chatPhotoPicker: picker, photoSaver: saver);
  backend.emit(StateEvent(sampleRoom()));
  backend.emit(history(await messages(backend, room)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(S.chat));
  await tester.pumpAndSettle();
  return (backend, room);
}

Finder get stack => find.byKey(const ValueKey('photo-stack'));
Finder back(int k) => find.byKey(ValueKey('photo-stack-back-$k'));

double dxOf(WidgetTester tester, Finder card) => tester.widget<Transform>(card).transform.getTranslation().x;

void main() {
  group('a message with pictures in the chat', () {
    for (final (count, backs) in [(2, 1), (3, 2), (10, 2)]) {
      testWidgets('$count pictures are a stack with $backs card(s) behind', (tester) async {
        await openChat(tester, (backend, room) async {
          final album = await makeAlbum(tester, backend, room, count);
          return [albumMessage(1, album)];
        });
        expect(stack, findsOneWidget);
        expect(find.byKey(const ValueKey('photo-stack-top')), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('photo-stack-back-'),
          ),
          findsNWidgets(backs),
        );
        expect(tester.widget<Text>(find.byKey(const ValueKey('photo-stack-count'))).data, '$count');
        expect(find.byKey(const ValueKey('photo-stack-gif')), findsNothing);
        // The top card is 4:5, 60% of the screen wide but not past 240
        final top = tester.getSize(find.byKey(const ValueKey('photo-stack-top')));
        expect(top, const Size(240, 300));
      });
    }

    testWidgets('the cards behind lean to the sides, a little differently for each picture', (tester) async {
      await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 3);
        return [albumMessage(1, album)];
      });
      expect(dxOf(tester, back(0)), -10);
      expect(dxOf(tester, back(1)), 10);
      final left = tester.widget<Transform>(back(0)).transform;
      final right = tester.widget<Transform>(back(1)).transform;
      // Turned about -5 and +4 degrees, within a degree
      double degrees(Matrix4 m) => 180 / 3.14159265 * (m.entry(1, 0)).clamp(-1, 1);
      expect(degrees(left), inInclusiveRange(-6.5, -3.5));
      expect(degrees(right), inInclusiveRange(2.5, 5.5));
      // The same picture is turned the same way every time it is drawn
      await tester.pumpAndSettle();
      expect(tester.widget<Transform>(back(0)).transform, left);
    });

    testWidgets('a picture that moves is told by a GIF label on the stack', (tester) async {
      await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 4, gifs: {3});
        return [albumMessage(1, album)];
      });
      expect(find.byKey(const ValueKey('photo-stack-gif')), findsOneWidget);
    });

    testWidgets('one picture has no bubble, keeps its shape, and opens the viewer', (tester) async {
      await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 1);
        return [albumMessage(1, album)];
      });
      expect(find.byKey(const ValueKey('photo-single')), findsOneWidget);
      expect(stack, findsNothing);
      final size = tester.getSize(find.byKey(const ValueKey('photo-single')));
      expect(size.width, closeTo(540 * 0.72, 0.5));
      expect(size.height, closeTo(540 * 0.72 * 3 / 4, 0.5));
      final bubbles = find.descendant(
        of: find.byKey(const ValueKey('chat-message-1')),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color != null,
        ),
      );
      expect(bubbles, findsNothing);

      await tester.tap(find.byKey(const ValueKey('photo-single')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-viewer')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-page')), findsNothing);
    });

    testWidgets('a tall picture is not taller than 320', (tester) async {
      await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 1, w: 300, h: 900);
        return [albumMessage(1, album)];
      });
      final size = tester.getSize(find.byKey(const ValueKey('photo-single')));
      expect(size.height, 320);
      // 1:2 at most
      expect(size.width, closeTo(160, 0.5));
    });

    testWidgets('the caption is under the pictures, in a bubble', (tester) async {
      await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 2, caption: 'Hạ Long');
        return [albumMessage(1, album)];
      });
      expect(find.text('Hạ Long'), findsOneWidget);
    });

    testWidgets('a message of a kind this app does not know shows its words', (tester) async {
      await openChat(
        tester,
        (backend, room) async => [
          ChatMessage(
            id: 1,
            by: 'b',
            name: 'Binh',
            text: '🎲 a dice',
            at: 1790660600000,
            x: const {'k': 'dice', 'n': 4},
          ),
        ],
      );
      expect(find.text('🎲 a dice'), findsOneWidget);
      expect(stack, findsNothing);
    });

    testWidgets('a touch opens the album: all the pictures in a grid, then the viewer', (tester) async {
      final (backend, room) = await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 7, caption: 'trip');
        return [albumMessage(1, album)];
      });
      await tester.tap(stack);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-page')), findsOneWidget);
      expect(find.textContaining('Binh · 7 photos'), findsOneWidget);
      expect(find.byKey(const ValueKey('album-caption')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-save-all')), findsOneWidget);
      // Three to a row, 2 px apart
      final a = tester.getRect(find.byKey(const ValueKey('album-cell-pic0aaaaaaaaaaaaaaaaa')));
      final b = tester.getRect(find.byKey(const ValueKey('album-cell-pic1aaaaaaaaaaaaaaaaa')));
      expect(a.width, closeTo(a.height, 0.01));
      expect(b.left - a.right, closeTo(2, 0.01));
      expect(a.width, closeTo((540 - 4) / 3, 0.5));
      expect(room.media, isNotNull);
      expect(backend.calls.where((c) => c.startsWith('downloadMedia')), isEmpty);

      await tester.tap(find.byKey(const ValueKey('album-cell-pic2aaaaaaaaaaaaaaaaa')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-viewer')), findsOneWidget);
      expect(find.text('3/7'), findsOneWidget);
    });

    testWidgets('the stack fetches 3 pictures, the album page the rest', (tester) async {
      final (backend, _) = await openChat(tester, (backend, room) async {
        final album = await makeAlbum(tester, backend, room, 6, keep: false);
        return [albumMessage(1, album)];
      });
      await until(tester, () => backend.calls.where((c) => c.startsWith('downloadMedia')).length == 3);
      expect(backend.calls.where((c) => c.startsWith('downloadMedia')).toSet(), {
        'downloadMedia pic0aaaaaaaaaaaaaaaaa',
        'downloadMedia pic1aaaaaaaaaaaaaaaaa',
        'downloadMedia pic2aaaaaaaaaaaaaaaaa',
      });
      await tester.tap(stack);
      await tester.pumpAndSettle();
      await until(tester, () => backend.calls.where((c) => c.startsWith('downloadMedia')).length == 6);
    });

    testWidgets('with the system animations off the stack is drawn spread out and still, even when new', (
      tester,
    ) async {
      final (backend, room) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history([]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      final album = await makeAlbum(tester, backend, room, 3);
      backend.emit(arrived(albumMessage(1, album, at: DateTime.now().millisecondsSinceEpoch)));
      await tester.pump();
      await tester.pump();
      expect(dxOf(tester, back(0)), -10);
      // And a touch does not press it
      final touch = await tester.startGesture(tester.getCenter(stack));
      await tester.pump(const Duration(milliseconds: 150));
      expect(dxOf(tester, back(0)), -10);
      await touch.up();
      await tester.pumpAndSettle();
    });

    group('with animations', () {
      Future<void> animated(WidgetTester tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
      }

      testWidgets('a new message fans out from under the top card, with a spring', (tester) async {
        final (backend, room) = await pumpApp(tester);
        await animated(tester);
        backend.emit(StateEvent(sampleRoom()));
        backend.emit(history([]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();

        final album = await makeAlbum(tester, backend, room, 3);
        backend.emit(arrived(albumMessage(1, album, at: DateTime.now().millisecondsSinceEpoch)));
        await tester.pump();
        await tester.pump();
        expect(dxOf(tester, back(0)), 0, reason: 'under the top card');
        // The first frame of an animation is its start
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(dxOf(tester, back(0)), lessThan(-1));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(dxOf(tester, back(0)), closeTo(-10, 0.01));
        expect(dxOf(tester, back(1)), closeTo(10, 0.01));
      });

      testWidgets('a touch opens the album with the page growing out of the stack, and going back shrinks it into it', (
        tester,
      ) async {
        final (backend, room) = await pumpApp(tester);
        await animated(tester);
        backend.emit(StateEvent(sampleRoom()));
        final album = await makeAlbum(tester, backend, room, 3);
        backend.emit(history([albumMessage(1, album)]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();

        await tester.tap(stack);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final window = find.ancestor(of: find.byKey(const ValueKey('album-page')), matching: find.byType(ClipRRect));
        expect(
          tester.getSize(window.first).width,
          lessThan(540),
          reason: 'part way, the page shows through a smaller window',
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(const ValueKey('album-page'))), const Size(540, 1200));
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('album-page')), findsNothing);
        expect(stack, findsOneWidget);
      });

      testWidgets('the history of the chat is not fanned out', (tester) async {
        final (backend, room) = await pumpApp(tester);
        await animated(tester);
        backend.emit(StateEvent(sampleRoom()));
        final album = await makeAlbum(tester, backend, room, 3);
        backend.emit(history([albumMessage(1, album)]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pump();
        expect(dxOf(tester, back(0)), -10);
        await tester.pumpAndSettle();
      });

      testWidgets('a finger down presses the stack, and letting go bounces it back', (tester) async {
        final (backend, room) = await pumpApp(tester);
        await animated(tester);
        backend.emit(StateEvent(sampleRoom()));
        final album = await makeAlbum(tester, backend, room, 3);
        backend.emit(history([albumMessage(1, album)]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();

        final top = find.byKey(const ValueKey('photo-stack-top'));
        double widthOf() => tester.getBottomRight(top).dx - tester.getTopLeft(top).dx;
        final widthBefore = widthOf();
        final touch = await tester.startGesture(tester.getCenter(stack));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        // The cards behind close in, and the whole is a little smaller
        expect(dxOf(tester, back(0)), closeTo(-5, 0.6));
        expect(widthOf(), lessThan(widthBefore));
        // Letting go without a tap, as when the finger turns into a swipe
        await touch.cancel();
        await tester.pumpAndSettle();
        expect(dxOf(tester, back(0)), closeTo(-10, 0.01));
        expect(widthOf(), closeTo(widthBefore, 0.01));
      });
    });

    testWidgets(
      'a long touch gives the menu of the message with Save all photos in place of Copy, and a swipe replies',
      (tester) async {
        final saved = <String>[];
        final (backend, room) = await openChat(
          tester,
          (backend, room) async {
            final album = await makeAlbum(tester, backend, room, 3);
            return [albumMessage(1, album)];
          },
          saver: (bytes, name, mime) async {
            saved.add('$mime ${bytes.length}');
            return PhotoSaveResult.saved;
          },
        );
        expect(room, isNotNull);
        await tester.drag(stack, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
        expect(find.textContaining('📷 3 photos'), findsWidgets);
        expect(backend.calls.where((c) => c.startsWith('sendChat')), isEmpty);

        await tester.longPress(stack);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('message-copy')), findsNothing);
        expect(find.byKey(const ValueKey('message-reply')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('message-save-all')));
        await tester.pumpAndSettle();
        expect(saved, hasLength(3));
        expect(find.text(S.photosSaved(3)), findsOneWidget);
      },
    );
  });

  group('the viewer', () {
    Future<List<String>> openViewer(WidgetTester tester, {PhotoSaver? saver, int count = 3}) async {
      final saved = <String>[];
      await openChat(
        tester,
        (backend, room) async {
          final album = await makeAlbum(tester, backend, room, count);
          return [albumMessage(1, album)];
        },
        saver:
            saver ??
            (bytes, name, mime) async {
              saved.add('$name $mime');
              return PhotoSaveResult.saved;
            },
      );
      await tester.tap(stack);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-cell-pic0aaaaaaaaaaaaaaaaa')));
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('swiping goes to the next picture, and the index follows', (tester) async {
      await openViewer(tester);
      expect(find.text('1/3'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
    });

    testWidgets('Save puts the picture in the gallery and says so', (tester) async {
      final saved = await openViewer(tester);
      await tester.tap(find.byKey(const ValueKey('viewer-save')));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single, endsWith('image/jpeg'));
      expect(find.text(S.photoSaved), findsOneWidget);
    });

    testWidgets('a refusal of the gallery is told', (tester) async {
      await openViewer(tester, saver: (_, _, _) async => PhotoSaveResult.denied);
      await tester.tap(find.byKey(const ValueKey('viewer-save')));
      await tester.pumpAndSettle();
      expect(find.text(S.photoSaveDenied), findsOneWidget);
    });

    testWidgets('a double tap zooms in, and a zoomed picture is not swiped away from', (tester) async {
      await openViewer(tester);
      final at = tester.getCenter(find.byType(PageView));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(find.byType(PageView)).physics, isA<NeverScrollableScrollPhysics>());
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(find.byType(PageView)).physics, isA<PageScrollPhysics>());
    });

    testWidgets('pulling the picture down leaves', (tester) async {
      await openViewer(tester);
      final touch = await tester.startGesture(tester.getCenter(find.byType(PageView)));
      for (var i = 0; i < 10; i++) {
        await touch.moveBy(const Offset(0, 30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await touch.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-viewer')), findsNothing);
      expect(find.byKey(const ValueKey('album-page')), findsOneWidget);
    });

    testWidgets('Save all on the album page saves every picture', (tester) async {
      final saved = <String>[];
      await openChat(
        tester,
        (backend, room) async {
          final album = await makeAlbum(tester, backend, room, 4);
          return [albumMessage(1, album)];
        },
        saver: (bytes, name, mime) async {
          saved.add(name);
          return PhotoSaveResult.saved;
        },
      );
      await tester.tap(stack);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-save-all')));
      await tester.pumpAndSettle();
      expect(saved, hasLength(4));
      expect(saved.toSet(), hasLength(4), reason: 'a name of its own for each');
      expect(find.text(S.photosSaved(4)), findsOneWidget);
    });
  });

  group('sending pictures', () {
    Future<List<PickedPhoto>> picked(int n) async => [
      for (var i = 0; i < n; i++) PickedPhoto(solidPng(30 * i, 120, 60, side: 12), '${'abcdef'[i]}.png'),
    ];

    Future<(FakeBackend, RoomController)> chatWith(WidgetTester tester, ChatPhotoPicker picker) => openChat(
      tester,
      (backend, room) async => [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hi', at: 1790660600000)],
      picker: picker,
    );

    /// Taps the photo button and the photo library, and waits for the photos to be made ready and shown.
    Future<void> pick(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the button offers the library and the camera on a phone', (tester) async {
      final asked = <PhotoSource>[];
      await chatWith(tester, (source) async {
        asked.add(source);
        return const [];
      });
      expect(find.byTooltip(S.chatAddPhoto), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-add-photo')));
      await tester.pumpAndSettle();
      expect(find.text(S.photoGallery), findsOneWidget);
      expect(find.text(S.photoCamera), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('photo-source-camera')));
      await tester.pumpAndSettle();
      expect(asked, [PhotoSource.camera]);
      // Nothing picked: no preview
      expect(find.byKey(const ValueKey('photo-preview-count')), findsNothing);
    });

    testWidgets('picked photos wait on a ring, then show before they are sent; cancel sends nothing', (tester) async {
      final (backend, room) = await chatWith(tester, (_) async => picked(3));
      await pick(tester);
      expect(find.byKey(const ValueKey('chat-photo-preparing')), findsOneWidget);
      await previewShown(tester);
      expect(find.byKey(const ValueKey('chat-photo-preparing')), findsNothing);
      expect(find.text(S.photoCount(3)), findsOneWidget);
      expect(find.text(S.photoReorderHint), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('photo-preview-cancel')));
      await tester.pumpAndSettle();
      expect(room.chat.value, hasLength(1));
      expect(backend.calls.where((c) => c.startsWith('mediaTickets')), isEmpty);
    });

    testWidgets('a photo is taken out with its cross, a caption is written, and Send sends the rest', (tester) async {
      final (backend, room) = await chatWith(tester, (_) async => picked(3));
      await pick(tester);
      await previewShown(tester);
      await tester.tap(find.byKey(const ValueKey('photo-remove-1')));
      await tester.pump();
      expect(find.text(S.photoCount(2)), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('photo-caption')), '  Sunday  ');
      await tester.tap(find.byKey(const ValueKey('photo-preview-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('photo-preview-count')), findsNothing);
      expect(backend.calls, contains('sendChat 📷 2 photos Sunday'));
      expect(AlbumExtra.fromJson(backend.lastExtra!).items, hasLength(2));
      expect(AlbumExtra.fromJson(backend.lastExtra!).caption, 'Sunday');
      expect(room.chat.value.last.delivery, ChatDelivery.sending);
      // The pictures are in the chat already, as a stack
      expect(stack, findsOneWidget);
      await endWait(tester);
    });

    testWidgets('dragging a photo changes the order they are sent in', (tester) async {
      final (_, room) = await chatWith(tester, (_) async => picked(3));
      await pick(tester);
      await previewShown(tester);
      final first = tester.getCenter(find.byKey(const ValueKey('photo-remove-0'))) + const Offset(-20, 40);
      final touch = await tester.startGesture(first);
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 0; i < 12; i++) {
        await touch.moveBy(const Offset(25, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await touch.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-preview-send')));
      await tester.pumpAndSettle();
      final names = room.albumUploads.value.values.single.photos.map((p) => p.name).toList();
      expect(names, hasLength(3));
      expect(names.first, isNot('a.png'), reason: 'the first photo was moved off the first place');
      expect(names.toSet(), {'a.png', 'b.png', 'c.png'});
      await endWait(tester);
    });

    testWidgets('what cannot be sent is told, and the rest goes on', (tester) async {
      await chatWith(
        tester,
        (_) async => [...await picked(1), PickedPhoto(Uint8List.fromList(List.filled(40, 7)), 'bad.bin')],
      );
      await pick(tester);
      await previewShown(tester);
      expect(find.text(S.chatPhotoUnreadable('bad.bin')), findsOneWidget);
      expect(find.text(S.photoCount(1)), findsOneWidget);
    });

    testWidgets('removing every photo closes the preview', (tester) async {
      await chatWith(tester, (_) async => picked(1));
      await pick(tester);
      await previewShown(tester);
      await tester.tap(find.byKey(const ValueKey('photo-remove-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-preview-count')), findsNothing);
    });

    testWidgets('the quote above the field goes with the pictures', (tester) async {
      final (backend, room) = await chatWith(tester, (_) async => picked(2));
      await tester.drag(find.text('hi'), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
      await pick(tester);
      await previewShown(tester);
      await tester.tap(find.byKey(const ValueKey('photo-preview-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
      expect(backend.calls, contains('sendChat 📷 2 photos reply 1'));
      expect(room.chat.value.last.reply?.id, 1);
      await endWait(tester);
    });

    testWidgets('a GIF pasted from the keyboard goes through the same preview, and stays a GIF', (tester) async {
      final (backend, _) = await chatWith(tester, (_) async => const []);
      final gif = img.encodeGif(img.Image(width: 20, height: 10));
      final config = tester.widget<TextField>(find.byKey(const ValueKey('chat-field'))).contentInsertionConfiguration!;
      expect(config.allowedMimeTypes, contains('image/gif'));
      config.onContentInserted(KeyboardInsertedContent(mimeType: 'image/gif', uri: 'content://x/fun.gif', data: gif));
      await tester.pump();
      await previewShown(tester);
      expect(find.text('GIF'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('photo-preview-send')));
      await tester.pumpAndSettle();
      expect(AlbumExtra.fromJson(backend.lastExtra!).items.single.mime, 'image/gif');
      await endWait(tester);
    });
  });

  group('pictures on their way', () {
    Future<(FakeBackend, RoomController, List<PreparedPhoto>)> inChat(WidgetTester tester, int n) async {
      final (backend, room) = await openChat(tester, (backend, room) async => []);
      return (backend, room, [for (var i = 0; i < n; i++) await prepared(tester, i)]);
    }

    testWidgets('previews with a ring and how many are up; the message becomes the room’s when it is confirmed', (
      tester,
    ) async {
      final (backend, room, photos) = await inChat(tester, 3);
      final gate = Completer<bool>();
      backend.onUpload = (t) => t.token == 'tok0' ? Future.value(true) : gate.future;
      unawaited(room.sendAlbum(photos));
      await tester.pump();
      await tester.pump();

      expect(stack, findsOneWidget);
      expect(find.byKey(const ValueKey('photo-progress')), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      // Nothing opens yet
      await tester.tap(stack);
      await tester.pump();
      expect(find.byKey(const ValueKey('album-page')), findsNothing);

      gate.complete(true);
      await tester.pump();
      await tester.pump();
      final cid = backend.lastChatCid!;
      final extra = AlbumExtra.fromJson(backend.lastExtra!);
      backend.emit(
        arrived(
          ChatMessage(
            id: 5,
            by: 'me',
            name: 'Anna',
            text: S.chatPhotoText(3),
            at: DateTime.now().millisecondsSinceEpoch,
            cid: cid,
            x: extra.toJson(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-progress')), findsNothing);
      expect(stack, findsOneWidget);
      await tester.tap(stack);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-page')), findsOneWidget);
      expect(find.textContaining('${S.you} · 3 photos'), findsOneWidget);
    });

    testWidgets('a failed file shows a red mark, and a touch tries again', (tester) async {
      final (backend, room, photos) = await inChat(tester, 2);
      var broken = true;
      backend.onUpload = (t) async => !(broken && t.token == 'tok1');
      await room.sendAlbum(photos);
      await tester.pump();
      expect(find.byKey(const ValueKey('photo-failed')), findsOneWidget);
      expect(find.text(S.chatNotSent), findsOneWidget);
      expect(room.chat.value.single.delivery, ChatDelivery.failed);

      broken = false;
      await tester.tap(stack);
      await tester.pump();
      await tester.pump();
      expect(backend.calls, contains('sendChat 📷 2 photos'));
      expect(find.byKey(const ValueKey('photo-failed')), findsNothing);
      await endWait(tester);
    });

    testWidgets('a room out of space says so instead', (tester) async {
      final (backend, room, photos) = await inChat(tester, 2);
      backend.ticketsFor = (_) => const MediaTickets.refused('media_full');
      await room.sendAlbum(photos);
      await tester.pump();
      expect(find.text(S.chatPhotosFull), findsOneWidget);
      expect(find.text(S.chatNotSent), findsNothing);
    });

    testWidgets('the menu of a message that is not sent can take it back', (tester) async {
      final (backend, room, photos) = await inChat(tester, 2);
      backend.ticketsFor = (_) => const MediaTickets.refused('media_unavailable');
      await room.sendAlbum(photos);
      await tester.pump();
      await tester.longPress(stack);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-copy')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('message-cancel-send')));
      await tester.pumpAndSettle();
      expect(room.chat.value, isEmpty);
      expect(room.albumUploads.value, isEmpty);
      expect(stack, findsNothing);
    });
  });
}
