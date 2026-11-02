import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/sticker_licenses.dart';
import 'package:sapoche/data/sticker_store.dart';
import 'package:sapoche/format.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/sticker_tray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_song_test.dart' as song show entry, history, other, room;
import 'fake_backend.dart';
import 'pump_app.dart';
import 'sticker_fixture.dart';

ChatMessage stickerMessage(int id, StickerExtra extra, {String by = 'b'}) => ChatMessage(
  id: id,
  by: by,
  name: by == 'me' ? 'Anna' : 'Binh',
  text: extra.emoji,
  at: 1790660600000 + id * 1000,
  x: extra.toJson(),
);

StickerExtra grin([String pack = 'noto']) => StickerExtra(pack: pack, sticker: '1f600', emoji: '😀');

/// The chat of a room, open, with [messages] in it and [store] for stickers.
Future<(FakeBackend, StickerStore)> openChat(
  WidgetTester tester,
  StickerServer server, {
  StickerDisk? disk,
  List<ChatMessage> messages = const [],
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = await stickerStore(server, disk: disk);
  final (backend, _) = await pumpApp(tester, stickers: store);
  backend.emit(StateEvent(song.room([song.entry('q0', song.other)])));
  backend.emit(song.history(messages));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(S.chat));
  await tester.pumpAndSettle();
  return (backend, store);
}

Finder get field => find.byKey(const ValueKey('chat-field'));
Finder get stickerButton => find.byKey(const ValueKey('chat-add-sticker'));
Finder get tray => find.byType(StickerTray);
Finder get search => find.byKey(const ValueKey('sticker-search'));
Finder cell(String pack, String id) => find.byKey(ValueKey('sticker-$pack-$id'));
Finder get photo => find.byKey(const ValueKey('chat-add-photo'));
Finder get songButton => find.byKey(const ValueKey('chat-add-song'));
Finder get more => find.byKey(const ValueKey('chat-attach-more'));
Finder get inChat => find.byKey(const ValueKey('chat-sticker'));

Future<void> openTray(WidgetTester tester) async {
  await tester.tap(stickerButton);
  await tester.pumpAndSettle();
}

/// Lets the pictures drawn so far be decoded, which takes the engine real time.
Future<void> decoded(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump();
  await tester.pump();
}

void main() {
  late StickerServer server;

  setUp(() => server = StickerServer());

  group('the tray', () {
    testWidgets('opens in the place of the keyboard, and the field brings the keyboard back', (tester) async {
      await openChat(tester, server);
      expect(find.byTooltip(S.chatAddSticker), findsOneWidget);
      expect(tray, findsNothing);

      await tester.showKeyboard(field);
      expect(tester.testTextInput.isVisible, isTrue);
      await openTray(tester);
      expect(tray, findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      // No keyboard has been seen to take the height of
      expect(tester.getSize(tray).height, 300);

      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(tray, findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('the sticker button, touched again, puts the keyboard back', (tester) async {
      await openChat(tester, server);
      await openTray(tester);
      expect(find.byTooltip(S.chatKeyboard), findsOneWidget);
      await openTray(tester);
      expect(tray, findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byTooltip(S.chatAddSticker), findsOneWidget);
    });

    testWidgets('is as tall as the keyboard was, and keeps the chat laid out', (tester) async {
      await openChat(tester, server);
      await tester.showKeyboard(field);
      tester.view.viewInsets = const FakeViewPadding(bottom: 700);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final fieldWhileTyping = tester.getRect(field);

      tester.view.resetViewInsets();
      await openTray(tester);
      expect(tester.getSize(tray).height, 350);
      // The field stays where it was above the keyboard; the stickers are where the keyboard was
      expect(tester.getRect(field).bottom, closeTo(fieldWhileTyping.bottom, 1));
      expect(tester.getRect(tray).top, greaterThanOrEqualTo(tester.getRect(field).bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('is a smaller one over the keyboard while the search is written', (tester) async {
      await openChat(tester, server);
      // 393x852 with a keyboard of 336
      tester.view.physicalSize = const Size(393 * 2, 852 * 2);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await openTray(tester);
      expect(tester.getSize(tray).height, 300);

      tester.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
      await tester.pumpAndSettle();
      expect(tray, findsOneWidget);
      expect(tester.getSize(tray).height, closeTo(852 - 336 - 340, 1));
      expect(tester.getRect(tray).bottom, lessThanOrEqualTo(852 - 336));
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(tester.getRect(tray).top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens on the first pack added, and each tab shows its own stickers', (tester) async {
      await openChat(tester, server);
      await openTray(tester);
      expect(cell('noto', '1f600'), findsOneWidget);
      expect(cell('noto', '1f436'), findsOneWidget);
      expect(cell('fluent', '2764'), findsNothing);
      expect(find.byKey(const ValueKey('sticker-tab-noto')), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-tab-fluent')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sticker-tab-extra')),
        findsNothing,
        reason: 'only three packs are there at first',
      );

      await tester.tap(find.byKey(const ValueKey('sticker-tab-fluent')));
      await tester.pumpAndSettle();
      expect(cell('fluent', '2764'), findsOneWidget);
      expect(cell('noto', '1f600'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sticker-tab-recent')));
      await tester.pumpAndSettle();
      expect(find.text(S.stickerRecentEmpty), findsOneWidget);
    });

    testWidgets('opens on the recent ones when there are some, the latest first', (tester) async {
      await openChat(
        tester,
        server,
        prefs: {
          'stickers.recent': [
            '{"k":"stk","p":"fluent","s":"2764","e":"❤"}',
            '{"k":"stk","p":"noto","s":"1f436","e":"🐶"}',
          ],
        },
      );
      await openTray(tester);
      expect(cell('fluent', '2764'), findsOneWidget);
      expect(cell('noto', '1f436'), findsOneWidget);
      expect(cell('noto', '1f600'), findsNothing);
      expect(tester.getTopLeft(cell('fluent', '2764')).dx, lessThan(tester.getTopLeft(cell('noto', '1f436')).dx));
    });

    testWidgets('finds stickers by their keywords and by the emoji, in every pack added', (tester) async {
      await openChat(tester, server);
      await openTray(tester);

      await tester.enterText(search, 'dog');
      await tester.pumpAndSettle();
      expect(cell('noto', '1f436'), findsOneWidget);
      expect(cell('noto', '1f600'), findsNothing);

      // Part of a word, and a pack that is not the one open
      await tester.enterText(search, 'LOV');
      await tester.pumpAndSettle();
      expect(cell('fluent', '2764'), findsOneWidget);
      expect(cell('noto', '1f436'), findsNothing);

      await tester.enterText(search, '😀');
      await tester.pumpAndSettle();
      expect(cell('noto', '1f600'), findsOneWidget);
      expect(cell('fluent', '1f600'), findsOneWidget, reason: 'the same emoji in each pack that has it');
      expect(cell('noto', '1f602'), findsNothing);

      await tester.enterText(search, 'zzz');
      await tester.pumpAndSettle();
      expect(find.text(S.stickerNoMatch), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sticker-search-clear')));
      await tester.pumpAndSettle();
      expect(cell('noto', '1f600'), findsOneWidget);
      expect(cell('noto', '1f436'), findsOneWidget);
    });

    testWidgets('sends a sticker at once, with its emoji as the words, and stays open', (tester) async {
      final (backend, store) = await openChat(tester, server);
      await openTray(tester);
      await tester.tap(cell('noto', '1f600'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('sendChat 😀'));
      expect(backend.lastExtra, {'k': 'stk', 'p': 'noto', 's': '1f600', 'e': '😀'});
      expect(tray, findsOneWidget);
      expect(inChat, findsOneWidget, reason: 'it shows in the chat as a sticker');
      expect(store.recent.single.sticker, '1f600');

      await tester.tap(cell('noto', '1f436'));
      await tester.pumpAndSettle();
      expect(backend.lastExtra, {'k': 'stk', 'p': 'noto', 's': '1f436', 'e': '🐶'});
      expect(inChat, findsNWidgets(2));
      expect(store.recent.map((s) => s.sticker), ['1f436', '1f600']);
      // What is in the field is not touched
      expect(tray, findsOneWidget);
      await tester.pump(const Duration(seconds: 11)); // the sends give up waiting for the room
    });

    testWidgets('the grid of the recent ones stays as it was while stickers are sent from it, and is new on return', (
      tester,
    ) async {
      await openChat(
        tester,
        server,
        prefs: {
          'stickers.recent': [
            '{"k":"stk","p":"noto","s":"1f600","e":"😀"}',
            '{"k":"stk","p":"noto","s":"1f436","e":"🐶"}',
          ],
        },
      );
      await openTray(tester);
      final dogBefore = tester.getTopLeft(cell('noto', '1f436'));
      await tester.tap(cell('noto', '1f436'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(cell('noto', '1f436')), dogBefore);
      await tester.tap(find.byKey(const ValueKey('sticker-tab-fluent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sticker-tab-recent')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(cell('noto', '1f436')).dx, lessThan(tester.getTopLeft(cell('noto', '1f600')).dx));
      await tester.pump(const Duration(seconds: 11)); // the sends give up waiting for the room
    });

    testWidgets('answers the quote above the field when there is one', (tester) async {
      final (backend, _) = await openChat(
        tester,
        server,
        messages: [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hi there', at: 1790660601000)],
      );
      await tester.longPress(find.text('hi there'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);

      await openTray(tester);
      await tester.tap(cell('noto', '1f600'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('sendChat 😀 reply 1'));
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
      expect(tray, findsOneWidget);
      await tester.pump(const Duration(seconds: 11)); // the sends give up waiting for the room
    });

    testWidgets('shows a sticker big while it is held, and sends nothing', (tester) async {
      final (backend, _) = await openChat(tester, server);
      await openTray(tester);
      final preview = find.byKey(const ValueKey('sticker-preview'));
      expect(preview, findsNothing);

      final hold = await tester.startGesture(tester.getCenter(cell('noto', '1f602')));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(preview, findsOneWidget);
      expect(tester.getSize(preview), const Size(280, 280));

      await hold.up();
      await tester.pumpAndSettle();
      expect(preview, findsNothing);
      expect(backend.calls.where((c) => c.startsWith('sendChat')), isEmpty);
      expect(tray, findsOneWidget);
    });

    testWidgets('says so when the server has no packs, and the store button is still there', (tester) async {
      server.html = true;
      await openChat(tester, server);
      await openTray(tester);
      expect(find.text(S.stickerNone), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-store-button')), findsOneWidget);
    });
  });

  group('a sticker in the chat', () {
    testWidgets('is drawn on its own, 128 px square, with no bubble and not as a big emoji', (tester) async {
      await openChat(tester, server, messages: [stickerMessage(1, grin())]);
      expect(inChat, findsOneWidget);
      expect(tester.getSize(inChat), const Size(128, 128));
      expect(find.descendant(of: inChat, matching: find.byType(Image)), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-big-emoji')), findsNothing);
      expect(find.text('😀'), findsNothing);
      // No bubble: nothing of the colour of a message is behind it
      expect(
        find.ancestor(of: inChat, matching: find.byType(DecoratedBox)).evaluate().where((e) {
          final box = e.widget as DecoratedBox;
          return box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).borderRadius == BorderRadius.circular(18);
        }),
        isEmpty,
      );
    });

    testWidgets('is the emoji, big, where its pack is gone from the server', (tester) async {
      await openChat(
        tester,
        server,
        messages: [stickerMessage(1, const StickerExtra(pack: 'old', sticker: '1f600', emoji: '😀'))],
      );
      expect(find.byKey(const ValueKey('sticker-fallback')), findsOneWidget);
      expect(find.text('😀'), findsOneWidget);
      expect(tester.getSize(inChat), const Size(128, 128));
    });

    testWidgets('is the emoji where the server has the pack but not the sticker', (tester) async {
      await openChat(
        tester,
        server,
        messages: [stickerMessage(1, const StickerExtra(pack: 'noto', sticker: 'gone', emoji: '🙈'))],
      );
      expect(find.text('🙈'), findsOneWidget);
    });

    testWidgets('of a pack that is not added is fetched by itself, the pack not at all', (tester) async {
      final disk = MemoryStickerDisk();
      final (_, store) = await openChat(
        tester,
        server,
        disk: disk,
        messages: [stickerMessage(1, const StickerExtra(pack: 'extra', sticker: '1f389', emoji: '🎉'))],
      );
      expect(find.descendant(of: inChat, matching: find.byType(Image)), findsOneWidget);
      expect(server.imageRequests('extra'), 1);
      expect(store.isAdded('extra'), isFalse);
      expect(disk.files.keys.where((k) => k.startsWith('extra/')), ['extra/1f389.webp']);
    });

    testWidgets('keeps the frame of a message: a long touch offers a reply', (tester) async {
      await openChat(tester, server, messages: [stickerMessage(1, grin())]);
      await tester.longPress(inChat);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
    });

    testWidgets('of this device, still on its way, is shown too', (tester) async {
      final (backend, _) = await openChat(tester, server);
      backend.chatConnected = false;
      await openTray(tester);
      await tester.tap(cell('noto', '1f600'));
      await tester.pump();
      expect(inChat, findsOneWidget);
    });

    testWidgets('a message that only has the emoji of a kind this app does not know stays a big emoji', (tester) async {
      await openChat(
        tester,
        server,
        messages: [
          ChatMessage(id: 1, by: 'b', name: 'Binh', text: '😀', at: 1790660601000, x: const {'k': 'zzz'}),
        ],
      );
      expect(find.byKey(const ValueKey('chat-big-emoji')), findsOneWidget);
      expect(inChat, findsNothing);
    });

    testWidgets('a plain emoji sent as words is still a big emoji', (tester) async {
      await openChat(
        tester,
        server,
        messages: [ChatMessage(id: 1, by: 'b', name: 'Binh', text: '😀', at: 1790660601000)],
      );
      expect(find.byKey(const ValueKey('chat-big-emoji')), findsOneWidget);
    });
  });

  group('the animation', () {
    testWidgets('stops when the system asks for no animations, goes on when it does not, and stops again in calm', (
      tester,
    ) async {
      await openChat(tester, server, messages: [stickerMessage(1, grin())]);
      await decoded(tester);
      final image = find.descendant(of: inChat, matching: find.byType(Image));
      bool moving() => TickerMode.valuesOf(tester.element(image)).enabled;

      // pumpApp turns the animations of the system off
      expect(moving(), isFalse);

      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
      await tester.pump();
      expect(moving(), isTrue);

      Calm.chosen = true;
      addTearDown(() => Calm.chosen = null);
      await tester.pump();
      expect(moving(), isFalse, reason: 'calm mode');

      Calm.chosen = false;
      await tester.pump();
      expect(moving(), isTrue);
    });

    testWidgets('the tray plays what is on screen, and not when the system asks for no animations', (tester) async {
      await openChat(tester, server);
      await openTray(tester);
      await decoded(tester);
      final image = find.descendant(of: cell('noto', '1f600'), matching: find.byType(Image));
      expect(TickerMode.valuesOf(tester.element(image)).enabled, isFalse);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
      await tester.pump();
      expect(TickerMode.valuesOf(tester.element(image)).enabled, isTrue);
    });
  });

  group('the buttons that add to a message', () {
    testWidgets('fold into one while there are words in the field, and open out when it is touched', (tester) async {
      await openChat(tester, server);
      expect([photo, songButton, stickerButton].map((f) => f.evaluate().length), [1, 1, 1]);
      expect(more, findsNothing);
      final empty = tester.getSize(field).width;

      await tester.enterText(field, 'hi');
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      expect([photo, songButton, stickerButton].map((f) => f.evaluate().length), [0, 0, 0]);
      expect(tester.getSize(field).width, greaterThan(empty + 48), reason: 'the field is wider');

      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(more, findsNothing);
      expect([photo, songButton, stickerButton].map((f) => f.evaluate().length), [1, 1, 1]);
      expect(find.text('hi'), findsOneWidget, reason: 'the words stay');
    });

    testWidgets('are all back when the field is emptied, and fold again when words come', (tester) async {
      await openChat(tester, server);
      await tester.enterText(field, 'hi');
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();

      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      expect(photo, findsOneWidget);
      expect(more, findsNothing);

      await tester.enterText(field, 'again');
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      expect(photo, findsNothing);
    });

    testWidgets('are all back after the words are sent', (tester) async {
      await openChat(tester, server);
      await tester.enterText(field, 'hi');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pumpAndSettle();
      expect(photo, findsOneWidget);
      expect(stickerButton, findsOneWidget);
      await tester.pump(const Duration(seconds: 11)); // the sends give up waiting for the room
    });

    testWidgets('keep the keyboard up when the one button is touched', (tester) async {
      await openChat(tester, server);
      await tester.showKeyboard(field);
      await tester.enterText(field, 'hi');
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
    });
  });

  group('the store', () {
    Future<void> openStore(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sticker-store-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the packs with what they weigh, who made them, and the way to add or remove each', (
      tester,
    ) async {
      final (_, store) = await openChat(tester, server, disk: MemoryStickerDisk());
      await openTray(tester);
      await openStore(tester);
      expect(find.text(S.stickerStore), findsOneWidget);
      for (final id in ['noto', 'fluent', 'plain', 'extra']) {
        expect(find.byKey(ValueKey('sticker-pack-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Pack noto'), findsOneWidget);
      expect(find.text('${S.stickerCount(3)} · ${formatBytes(3300000)}'), findsWidgets);
      expect(find.text('3 stickers · 3.1 MB'), findsWidgets);
      expect(find.text(S.stickerCredit('Noto Animated Emoji', 'Google', 'CC BY 4.0')), findsOneWidget);
      expect(find.text('Art: Art of fluent by Someone · MIT'), findsOneWidget);
      // The first three are added, the fourth is not
      expect(find.byKey(const ValueKey('sticker-remove-noto')), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-add-noto')), findsNothing);
      expect(find.byKey(const ValueKey('sticker-add-extra')), findsOneWidget);
      // A strip of the first stickers
      expect(
        find.descendant(of: find.byKey(const ValueKey('sticker-pack-noto')), matching: find.byType(Image)),
        findsNWidgets(3),
      );
      expect(store.added, ['noto', 'fluent', 'plain']);
    });

    testWidgets('is in the language of the app', (tester) async {
      await openChat(tester, server);
      await openTray(tester);
      S.current = 'vi';
      await openStore(tester);
      expect(find.text('Bộ noto'), findsOneWidget);
      expect(find.text('3 nhãn dán · 3.1 MB'), findsWidgets);
      expect(find.text(S.stickerAddPack), findsOneWidget);
      expect(find.text('Thêm'), findsOneWidget);
    });

    testWidgets('adds a pack with the progress of its download, and shows it in the tray', (tester) async {
      final disk = MemoryStickerDisk();
      final (_, store) = await openChat(tester, server, disk: disk);
      await openTray(tester);
      await openStore(tester);
      // The strip of the store has fetched the first four stickers of the pack; the others wait
      server.hold(0);

      await tester.tap(find.byKey(const ValueKey('sticker-add-extra')));
      await tester.pump(const Duration(milliseconds: 100));
      final bar = find.byKey(const ValueKey('sticker-progress-extra'));
      expect(bar, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(bar).value, closeTo(0.5, 0.01));
      expect(find.text(S.stickerDownloading(50)), findsOneWidget);
      expect(store.isAdded('extra'), isTrue);
      // The pack can be taken off while it comes: the button says Remove already
      expect(find.byKey(const ValueKey('sticker-remove-extra')), findsOneWidget);

      server.gate!.complete();
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(store.state('extra'), StickerPackState.ready);
      expect(disk.files.keys, contains('extra/complete.mark'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticker-tab-extra')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sticker-tab-extra')));
      await tester.pumpAndSettle();
      expect(cell('extra', '1f389'), findsOneWidget);
    });

    testWidgets('removes a pack and its files, and the tray loses its tab', (tester) async {
      final disk = MemoryStickerDisk();
      final (_, store) = await openChat(tester, server, disk: disk);
      await openTray(tester);
      await openStore(tester);
      await tester.pumpAndSettle();
      expect(disk.files.keys.where((k) => k.startsWith('fluent/')), isNotEmpty);

      await tester.tap(find.byKey(const ValueKey('sticker-remove-fluent')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticker-add-fluent')), findsOneWidget);
      expect(store.isAdded('fluent'), isFalse);
      expect(disk.files.keys.where((k) => k.startsWith('fluent/')), isEmpty);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticker-tab-fluent')), findsNothing);
      expect(find.byKey(const ValueKey('sticker-tab-noto')), findsOneWidget);
    });

    testWidgets('in a browser only records the choice', (tester) async {
      final (_, store) = await openChat(tester, server);
      await openTray(tester);
      await openStore(tester);
      await tester.tap(find.byKey(const ValueKey('sticker-add-extra')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticker-remove-extra')), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-progress-extra')), findsNothing);
      expect(store.isAdded('extra'), isTrue);
    });

    testWidgets('offers to fetch again a pack that did not come whole', (tester) async {
      server.missing.add('extra/1f381');
      final (_, store) = await openChat(
        tester,
        server,
        disk: MemoryStickerDisk(),
        prefs: {
          'stickers.added': ['noto'],
        },
      );
      await openTray(tester);
      await openStore(tester);
      await tester.tap(find.byKey(const ValueKey('sticker-add-extra')));
      await tester.pumpAndSettle();
      expect(find.text(S.stickerNotDownloaded), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-download-extra')), findsOneWidget);
      expect(store.state('extra'), StickerPackState.notDownloaded);
    });

    testWidgets('is calm when the server has no stickers, and tries again when asked', (tester) async {
      server.html = true;
      await openChat(tester, server);
      await openTray(tester);
      await openStore(tester);
      expect(find.byKey(const ValueKey('sticker-store-closed')), findsOneWidget);
      expect(find.text(S.stickerStoreEmpty), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker-pack-noto')), findsNothing);

      server.html = false;
      await tester.tap(find.byKey(const ValueKey('sticker-store-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sticker-store-closed')), findsNothing);
      expect(find.byKey(const ValueKey('sticker-pack-noto')), findsOneWidget);
    });

    testWidgets('is calm when the server cannot be reached', (tester) async {
      server.down = true;
      await openChat(tester, server);
      await openTray(tester);
      await openStore(tester);
      expect(find.byKey(const ValueKey('sticker-store-closed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('has the licences, which include those of the art', (tester) async {
      registerStickerLicenses();
      await openChat(tester, server);
      await openTray(tester);
      await openStore(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('sticker-licenses')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const ValueKey('sticker-licenses')));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.text('Noto Animated Emoji'), findsOneWidget);
      expect(find.text('Fluent Emoji'), findsOneWidget);
    });
  });
}
