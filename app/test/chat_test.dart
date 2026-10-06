import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/chat_sheet.dart';
import 'package:sapoche/ui/widgets/reactions.dart';

import 'fake_backend.dart';
import 'player_panels_test.dart' show openPlayer;
import 'pump_app.dart';

ChatMessage message(int id, String by, String text, {String? cid, int? at}) =>
    ChatMessage(
      id: id,
      by: by,
      name: by == 'me' ? 'Anna' : 'Binh',
      text: text,
      at: at ?? 1790660600000 + id * 1000,
      cid: cid,
    );

ChatEvent history(List<ChatMessage> messages, {String room = 'ABC234'}) =>
    ChatEvent(room: room, messages: messages, replace: true);

ChatEvent arrived(ChatMessage m, {String room = 'ABC234'}) =>
    ChatEvent(room: room, messages: [m], replace: false);

void main() {
  group('the chat in the controller', () {
    late FakeBackend backend;
    late RoomController controller;
    late List<Notice> notices;

    setUp(() async {
      backend = FakeBackend();
      controller = RoomController(backend);
      await controller.start();
      notices = [];
      controller.notices.listen(notices.add);
      backend.emit(StateEvent(sampleRoom()));
      await settle();
    });

    tearDown(() => controller.dispose());

    test(
      'a room whose server keeps no chat has none, and sends no reactions',
      () async {
        expect(controller.hasChat, isFalse);
        controller.react(Reaction.heart);
        await controller.sendChat('hello');
        expect(controller.chat.value, isEmpty);
        expect(backend.calls, isNot(contains(startsWith('react'))));
        expect(backend.calls, isNot(contains(startsWith('sendChat'))));
      },
    );

    test(
      'the history on arriving is there to read, not counted as news',
      () async {
        var told = 0;
        controller.addListener(() => told++);
        backend.emit(
          history([message(1, 'b', 'hi'), message(2, 'b', 'anyone?')]),
        );
        await settle();
        expect(controller.hasChat, isTrue);
        expect(told, greaterThan(0));
        expect(controller.chat.value.map((m) => m.text), ['hi', 'anyone?']);
        expect(controller.unreadChat.value, 0);
        expect(notices, isEmpty);
      },
    );

    test('a message of somebody else is counted and told about until the chat is opened', () async {
      backend.emit(history([message(1, 'b', 'hi')]));
      backend.emit(arrived(message(2, 'b', 'are you there')));
      backend.emit(arrived(message(3, 'me', 'yes')));
      await settle();
      expect(controller.unreadChat.value, 1);
      expect(notices.single.text, 'Binh: are you there');
      expect(notices.single.opensChat, isTrue);

      controller.setChatOpen(true);
      expect(controller.unreadChat.value, 0);
      backend.emit(arrived(message(4, 'b', 'good')));
      await settle();
      expect(controller.unreadChat.value, 0);
      expect(notices, hasLength(1));

      controller.setChatOpen(false);
      backend.emit(arrived(message(5, 'b', 'bye')));
      await settle();
      expect(controller.unreadChat.value, 1);
    });

    test('the same message twice is shown once', () async {
      backend.emit(history([message(1, 'b', 'hi')]));
      backend.emit(arrived(message(2, 'b', 'again')));
      backend.emit(arrived(message(2, 'b', 'again')));
      await settle();
      expect(controller.chat.value.map((m) => m.id), [1, 2]);
    });

    test(
      'a reconnect brings the history again without counting it twice',
      () async {
        backend.emit(history([message(1, 'b', 'hi')]));
        backend.emit(arrived(message(2, 'b', 'new')));
        await settle();
        expect(controller.unreadChat.value, 1);
        backend.emit(
          history([
            message(1, 'b', 'hi'),
            message(2, 'b', 'new'),
            message(3, 'b', 'meanwhile'),
          ]),
        );
        await settle();
        expect(controller.chat.value.map((m) => m.id), [1, 2, 3]);
        expect(controller.unreadChat.value, 2);
      },
    );

    test(
      'the chat goes with the room, and another room brings its own',
      () async {
        backend.emit(history([message(1, 'b', 'hi')]));
        backend.emit(arrived(message(2, 'b', 'unread')));
        await settle();
        backend.emit(StateEvent(sampleRoom(local: true)));
        await settle();
        expect(controller.hasChat, isFalse);
        expect(controller.chat.value, isEmpty);
        expect(controller.unreadChat.value, 0);

        // The new room's history can come before the state that names the room
        backend.emit(history([message(7, 'b', 'other room')], room: 'XYZ789'));
        await settle();
        backend.emit(
          StateEvent(
            RoomSnapshot(
              room: 'XYZ789',
              you: 'me',
              members: sampleRoom().members,
            ),
          ),
        );
        await settle();
        expect(controller.hasChat, isTrue);
        expect(controller.chat.value.single.text, 'other room');
      },
    );

    test('a message of another room is not mixed in', () async {
      backend.emit(history([message(1, 'b', 'hi')]));
      backend.emit(arrived(message(9, 'b', 'stray'), room: 'XYZ789'));
      await settle();
      expect(controller.chat.value.map((m) => m.text), ['hi']);
    });

    test('a reaction of somebody else comes with their name', () async {
      final shown = <RoomReaction>[];
      controller.reactions.listen(shown.add);
      controller.watchReactions();
      backend.emit(const ReactionEvent('b', Reaction.fire, 3));
      backend.emit(const ReactionEvent('b', null, 1));
      await settle();
      expect(shown.single.name, 'Binh');
      expect(shown.single.reaction, Reaction.fire);
      expect(shown.single.count, 3);
      expect(shown.single.mine, isFalse);
    });
  });

  group('reactions that nothing was showing', () {
    late FakeBackend backend;
    late RoomController controller;
    late List<RoomReaction> shown;

    setUp(() async {
      backend = FakeBackend();
      controller = RoomController(backend);
      await controller.start();
      backend.emit(StateEvent(sampleRoom()));
      await settle();
      shown = [];
      controller.reactions.listen(shown.add);
    });

    tearDown(() => controller.dispose());

    Future<void> wait([int ms = 900]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test(
      'are shown, a few of them, when a place that shows them opens',
      () async {
        backend.emit(const ReactionEvent('b', Reaction.fire, 5));
        backend.emit(const ReactionEvent('b', Reaction.fire, 4));
        backend.emit(const ReactionEvent('b', Reaction.heart, 1));
        await wait(100);
        expect(shown, isEmpty);

        controller.watchReactions();
        await wait();
        // One of each kind, the taps added up and held to a few
        expect(shown.map((r) => (r.reaction, r.count, r.name)), [
          (Reaction.fire, RoomController.lateTaps, 'Binh'),
          (Reaction.heart, 1, 'Binh'),
        ]);
        controller.unwatchReactions();

        // Told once
        controller.watchReactions();
        await wait();
        expect(shown, hasLength(2));
      },
    );

    test(
      'that came while the screen was off are shown when it is back',
      () async {
        controller.watchReactions();
        backend.emit(const ReactionEvent('b', Reaction.clap, 2, late: true));
        await wait(100);
        expect(shown, isEmpty);
        await wait();
        expect(shown.single.reaction, Reaction.clap);
        expect(shown.single.count, 2);
      },
    );

    test('are shown as they come while a place shows them', () async {
      controller.watchReactions();
      backend.emit(const ReactionEvent('b', Reaction.wow, 1));
      await wait(50);
      expect(shown.single.reaction, Reaction.wow);
    });

    test('are kept to the last few kinds', () async {
      final kinds = Reaction.named.take(RoomController.lateKinds + 5).toList();
      for (final kind in kinds) {
        backend.emit(ReactionEvent('b', kind, 1));
      }
      await wait(50);
      controller.watchReactions();
      await wait(2500);
      expect(shown.map((r) => r.reaction), kinds.skip(5).toList());
    });
  });

  group('writing and reacting', () {
    Future<(FakeBackend, RoomController)> inRoom(WidgetTester tester) async {
      final backend = FakeBackend();
      final controller = RoomController(backend);
      addTearDown(controller.dispose);
      await controller.start();
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history([message(1, 'b', 'hi')]));
      await tester.pump();
      return (backend, controller);
    }

    testWidgets(
      'a message shows at once and becomes the room’s when it comes back',
      (tester) async {
        final (backend, controller) = await inRoom(tester);
        await controller.sendChat('  hello there  ');
        expect(backend.calls, contains('sendChat hello there'));
        final pending = controller.chat.value.last;
        expect(
          (pending.text, pending.delivery, pending.by),
          ('hello there', ChatDelivery.sending, 'me'),
        );

        backend.emit(
          arrived(message(2, 'me', 'hello there', cid: backend.lastChatCid)),
        );
        await tester.pump();
        expect(controller.chat.value.map((m) => (m.id, m.delivery)), [
          (1, ChatDelivery.sent),
          (2, ChatDelivery.sent),
        ]);
        // Long after, it is still sent
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
        expect(controller.chat.value.last.delivery, ChatDelivery.sent);
      },
    );

    testWidgets('an empty message is not sent', (tester) async {
      final (backend, controller) = await inRoom(tester);
      await controller.sendChat('   ');
      expect(backend.calls, isNot(contains(startsWith('sendChat'))));
      expect(controller.chat.value, hasLength(1));
    });

    testWidgets(
      'with no connection a message is shown as not sent, and can be sent again',
      (tester) async {
        final (backend, controller) = await inRoom(tester);
        backend.chatConnected = false;
        await controller.sendChat('lost');
        expect(controller.chat.value.last.delivery, ChatDelivery.failed);

        backend.chatConnected = true;
        backend.calls.clear();
        await controller.resendChat(controller.chat.value.last);
        expect(backend.calls, ['sendChat lost']);
        expect(
          controller.chat.value.where((m) => m.text == 'lost').single.delivery,
          ChatDelivery.sending,
        );
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
      },
    );

    testWidgets('a message the room never confirms is shown as not sent', (
      tester,
    ) async {
      final (_, controller) = await inRoom(tester);
      await controller.sendChat('into the void');
      await tester.pump(
        RoomController.chatDeliveryTimeout - const Duration(milliseconds: 100),
      );
      expect(controller.chat.value.last.delivery, ChatDelivery.sending);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.chat.value.last.delivery, ChatDelivery.failed);
    });

    testWidgets(
      'a message still on its way stays after a reconnect brings the history',
      (tester) async {
        final (backend, controller) = await inRoom(tester);
        await controller.sendChat('on its way');
        final cid = backend.lastChatCid;
        backend.emit(
          history([message(1, 'b', 'hi'), message(2, 'b', 'meanwhile')]),
        );
        await tester.pump();
        expect(controller.chat.value.map((m) => m.text), [
          'hi',
          'meanwhile',
          'on its way',
        ]);
        // And one the history already has is not shown twice
        backend.emit(
          history([
            message(1, 'b', 'hi'),
            message(2, 'b', 'meanwhile'),
            message(3, 'me', 'on its way', cid: cid),
          ]),
        );
        await tester.pump();
        expect(controller.chat.value.map((m) => (m.id, m.delivery)), [
          (1, ChatDelivery.sent),
          (2, ChatDelivery.sent),
          (3, ChatDelivery.sent),
        ]);
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
        expect(controller.chat.value.last.delivery, ChatDelivery.sent);
      },
    );

    testWidgets(
      'a message of somebody else arriving before this device’s own still on its way goes above it',
      (tester) async {
        final (backend, controller) = await inRoom(tester);
        await controller.sendChat('mine');
        backend.emit(arrived(message(2, 'b', 'theirs')));
        await tester.pump();
        expect(controller.chat.value.map((m) => m.text), [
          'hi',
          'theirs',
          'mine',
        ]);
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
      },
    );

    testWidgets(
      'a reaction shows here at once and quick taps go to the room together',
      (tester) async {
        final (backend, controller) = await inRoom(tester);
        final shown = <RoomReaction>[];
        controller.reactions.listen(shown.add);
        for (var i = 0; i < 3; i++) {
          controller.react(Reaction.heart);
        }
        controller.react(Reaction.clap);
        await tester.pump();
        expect(shown.map((r) => (r.reaction, r.mine)), [
          (Reaction.heart, true),
          (Reaction.heart, true),
          (Reaction.heart, true),
          (Reaction.clap, true),
        ]);
        expect(backend.calls, isNot(contains(startsWith('react'))));
        await tester.pump(RoomController.reactionGathering);
        expect(backend.calls.where((c) => c.startsWith('react')), [
          'react heart 3',
          'react clap 1',
        ]);

        // A burst is capped to what the room accepts in one message
        backend.calls.clear();
        for (var i = 0; i < 25; i++) {
          controller.react(Reaction.fire);
        }
        await tester.pump(RoomController.reactionGathering);
        expect(backend.calls, [
          'react fire ${RoomController.maxReactionCount}',
        ]);
      },
    );
  });

  group('on screen', () {
    Future<(FakeBackend, RoomController)> roomWithChat(
      WidgetTester tester,
    ) async {
      final (backend, room) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        history([message(1, 'b', 'hi there'), message(2, 'me', 'hello')]),
      );
      await tester.pumpAndSettle();
      return (backend, room);
    }

    testWidgets('a room whose server keeps no chat shows no way into it', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pumpAndSettle();
      expect(find.byType(ChatButton), findsOneWidget);
      expect(find.byTooltip(S.chat), findsNothing);
    });

    testWidgets(
      'the chat opens from the room, shows who said what, and sends what is written',
      (tester) async {
        final (backend, room) = await roomWithChat(tester);
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        expect(find.byType(ChatSheet), findsOneWidget);
        expect(find.text('hi there'), findsOneWidget);
        expect(find.text('hello'), findsOneWidget);
        // The others' name stands above what they wrote; this device's own does not
        expect(find.text('Binh'), findsWidgets);
        final theirs = tester.getCenter(find.text('hi there'));
        final mine = tester.getCenter(find.text('hello'));
        expect(mine.dx, greaterThan(theirs.dx));

        await tester.enterText(
          find.byKey(const ValueKey('chat-field')),
          'on my way',
        );
        await tester.pump();
        await tester.tap(find.byTooltip(S.chatSend));
        await tester.pump();
        expect(backend.calls, contains('sendChat on my way'));
        expect(find.text('on my way'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('chat-field')))
              .controller!
              .text,
          isEmpty,
        );

        backend.emit(
          arrived(message(3, 'me', 'on my way', cid: backend.lastChatCid)),
        );
        await tester.pumpAndSettle();
        expect(find.text('on my way'), findsOneWidget);
        expect(room.chat.value.last.delivery, ChatDelivery.sent);
      },
    );

    testWidgets(
      'the send key of the keyboard sends too, and an empty field sends nothing',
      (tester) async {
        final (backend, _) = await roomWithChat(tester);
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        final send = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send_rounded),
        );
        expect(send.onPressed, isNull);
        await tester.enterText(
          find.byKey(const ValueKey('chat-field')),
          'by the key',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        expect(backend.calls, contains('sendChat by the key'));
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
      },
    );

    testWidgets(
      'a message that did not go is marked, and a tap sends it again',
      (tester) async {
        final (backend, _) = await roomWithChat(tester);
        backend.chatConnected = false;
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('chat-field')),
          'lost',
        );
        await tester.pump();
        await tester.tap(find.byTooltip(S.chatSend));
        await tester.pumpAndSettle();
        expect(find.text(S.chatNotSent), findsOneWidget);

        backend.chatConnected = true;
        await tester.tap(find.text(S.chatNotSent));
        await tester.pump();
        expect(backend.calls.where((c) => c == 'sendChat lost'), hasLength(2));
        expect(find.text(S.chatNotSent), findsNothing);
        await tester.pump(RoomController.chatDeliveryTimeout * 2);
      },
    );

    testWidgets(
      'what comes while the chat is closed shows on its button and in a note that opens it',
      (tester) async {
        final (backend, room) = await roomWithChat(tester);
        backend.emit(arrived(message(3, 'b', 'look at this')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(room.unreadChat.value, 1);
        expect(
          find.byTooltip('${S.chat} · ${S.unreadMessages(1)}'),
          findsOneWidget,
        );
        expect(find.text('Binh: look at this'), findsOneWidget);

        // Called as the note's button would: in a test the note sits under the page it is shown over
        final action = tester.widget<SnackBarAction>(
          find.byType(SnackBarAction),
        );
        expect(action.label, S.chatOpen);
        action.onPressed();
        await tester.pumpAndSettle();
        expect(find.byType(ChatSheet), findsOneWidget);
        expect(room.unreadChat.value, 0);

        // While it is open nothing else tells about the messages
        backend.emit(arrived(message(4, 'b', 'and this')));
        await tester.pumpAndSettle();
        expect(find.text('and this'), findsOneWidget);
        expect(find.text('Binh: and this'), findsNothing);
        expect(room.unreadChat.value, 0);
      },
    );

    testWidgets('an empty chat says so', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history(const []));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      expect(find.text(S.chatEmpty), findsOneWidget);
    });

    testWidgets(
      'a long gap puts the time between messages, and a run of one person shows their name once',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(StateEvent(sampleRoom()));
        const start = 1790660600000;
        backend.emit(
          history([
            message(1, 'b', 'one', at: start),
            message(2, 'b', 'two', at: start + 60 * 1000),
            message(3, 'b', 'much later', at: start + 60 * 60 * 1000),
          ]),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        final sheet = find.byType(ChatSheet);
        expect(
          find.descendant(of: sheet, matching: find.text('Binh')),
          findsNWidgets(2),
        );
      },
    );

    testWidgets(
      'the player offers the way to the emoji in a room with a chat, and theirs fly up and go',
      (tester) async {
        final backend = await openPlayer(tester);
        moving(tester);
        expect(find.byTooltip(S.reactMore), findsNothing);
        backend.emit(history(const []));
        await tester.pump();
        expect(find.byType(ReactionBar), findsNothing);
        expect(find.byTooltip(S.reactMore), findsOneWidget);

        // Somebody else's, with their name, three taps one after another
        backend.emit(const ReactionEvent('b', Reaction.laugh, 3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(flying('😂'), 3);
        expect(find.text('Binh'), findsWidgets);

        // Then they are gone, and nothing keeps running
        await tester.pump(
          ReactionShower.flight + const Duration(milliseconds: 500),
        );
        expect(flying('😂'), 0);
      },
    );

    testWidgets(
      'the chat has the quick reactions, and a tap on one flies up and goes to the room',
      (tester) async {
        final backend = await openPlayer(tester);
        moving(tester);
        backend.emit(history(const []));
        await tester.pump();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        for (final reaction in Reaction.quick) {
          expect(
            find.byKey(ValueKey('react-${reaction.name}')),
            findsOneWidget,
          );
        }
        expect(find.byKey(const ValueKey('react-guitar')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('react-heart')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(flying('❤️'), greaterThan(0));
        await tester.pump(RoomController.reactionGathering);
        expect(backend.calls, contains('react heart 1'));
        await tester.pumpAndSettle();
      },
    );

    for (final (width, height) in [
      (360.0, 568.0),
      (375.0, 667.0),
      (360.0, 640.0),
      (393.0, 852.0),
    ]) {
      testWidgets('the player of a room with a chat fits ${width}x$height', (
        tester,
      ) async {
        final backend = await openPlayer(tester);
        tester.view.physicalSize = Size(width * 2, height * 2);
        backend.emit(history(const []));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        // Nothing of the controls is pushed off the screen or under another
        for (final tooltip in [S.chat, S.reactMore, S.lyrics, S.playOn]) {
          expect(
            find.byTooltip(tooltip).hitTestable(),
            findsOneWidget,
            reason: tooltip,
          );
        }
      });
    }

    testWidgets(
      'the chat stays below the island with the keyboard up, and a touch outside the field puts the keyboard away',
      (tester) async {
        // 393x852 with an island (59) at the top and a keyboard of 336 at the bottom
        final backend = await openPlayer(tester);
        tester.view.physicalSize = const Size(393 * 2, 852 * 2);
        tester.view.padding = const FakeViewPadding(
          top: 59 * 2,
          bottom: 34 * 2,
        );
        backend.emit(
          history([message(1, 'b', 'hello'), message(2, 'me', 'hi')]),
        );
        await tester.pump();
        await tester.tap(find.byTooltip(S.chat));
        await tester.pumpAndSettle();
        final sheet = find.byType(ChatSheet);

        await tester.tap(find.byKey(const ValueKey('chat-field')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
        await tester.pumpAndSettle();
        final typing = tester.getRect(sheet);
        expect(typing.top, greaterThanOrEqualTo(59));
        expect(
          tester.getRect(find.byKey(const ValueKey('chat-field'))).bottom,
          lessThanOrEqualTo(852 - 336),
        );
        expect(tester.testTextInput.isVisible, isTrue);

        await tester.tap(find.text('hello'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.view.resetPadding);
      },
    );

    testWidgets(
      'every emoji is a tap further, and picking one sends it and shows it flying',
      (tester) async {
        final backend = await openPlayer(tester);
        moving(tester);
        backend.emit(history(const []));
        await tester.pump();
        await tester.tap(find.byTooltip(S.reactMore));
        await tester.pumpAndSettle();
        expect(find.byType(EmojiPicker), findsOneWidget);

        // One the room has had by name goes by its name, so older apps show it too; and the sheet stays, to tap again
        await tester.tap(find.text('😍'));
        await tester.tap(find.text('😍'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(EmojiPicker), findsOneWidget);
        expect(flying('😍'), greaterThan(1));
        expect(backend.calls, contains('react love 2'));

        // Any other goes as itself
        await tester.tap(find.text('😀'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(EmojiPicker), findsOneWidget);
        expect(backend.calls, contains('react 😀 1'));

        // A touch outside puts it away
        await tester.tapAt(const Offset(200, 20));
        await tester.pumpAndSettle();
        expect(find.byType(EmojiPicker), findsNothing);
      },
    );

    test(
      'a name or an emoji from the room is a reaction, and nothing else is',
      () {
        expect(Reaction.parse('guitar'), Reaction.guitar);
        for (final e in ['🍕', '👍🏽', '🇻🇳', '👨‍👩‍👧‍👦', '1️⃣', '❤️']) {
          expect(Reaction.parse(e)?.emoji, e);
        }
        for (final e in [
          'poop',
          '12',
          '#',
          'a🍕',
          '<b>🍕</b>',
          '',
          '🍕' * 17,
        ]) {
          expect(Reaction.parse(e), isNull, reason: e);
        }
        expect(Reaction.parse(null), isNull);
        // An emoji picked that has a name goes by it
        expect(Reaction.of('🎸').wire, 'guitar');
        expect(Reaction.of('🍕').wire, '🍕');
      },
    );

    test('the reactions that go by name are the names the room has had', () {
      // The same names as REACTIONS in server/src/protocol.ts
      expect(Reaction.named.map((r) => r.name), [
        'heart',
        'love',
        'kiss',
        'hug',
        'blush',
        'cool',
        'wink',
        'pleading',
        'laugh',
        'rofl',
        'grin',
        'wow',
        'mindblown',
        'think',
        'eyes',
        'sad',
        'cry',
        'skull',
        'sleepy',
        'fire',
        'clap',
        'raise',
        'party',
        'hundred',
        'sparkles',
        'rocket',
        'muscle',
        'thumbsup',
        'thumbsdown',
        'ok',
        'pray',
        'music',
        'dance',
        'headphones',
        'mic',
        'guitar',
        'drum',
        'speaker',
        'replay',
      ]);
      expect(
        Reaction.named.map((r) => r.emoji).toSet(),
        hasLength(Reaction.named.length),
      );
      expect(Reaction.quick.map((r) => r.name), [
        'heart',
        'fire',
        'laugh',
        'wow',
        'sad',
        'clap',
      ]);
    });

    testWidgets('reactions pile up only so far', (tester) async {
      final backend = await openPlayer(tester);
      moving(tester);
      backend.emit(history(const []));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        backend.emit(const ReactionEvent('b', Reaction.fire, 10));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(flying('🔥'), ReactionShower.maxFlying);
      await tester.pump(ReactionShower.flight * 2);
      expect(flying('🔥'), 0);
    });

    testWidgets('outside a room the player has no reactions and no chat', (
      tester,
    ) async {
      final backend = await openPlayer(
        tester,
        snapshot: sampleRoom(local: true),
      );
      backend.emit(history(const []));
      await tester.pump();
      expect(find.byType(ReactionBar), findsNothing);
      expect(find.byTooltip(S.chat), findsNothing);
    });
  });
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Reactions [emoji] in the air, leaving out the button that sends it.
int flying(String emoji) =>
    find.text(emoji).evaluate().length -
    find
        .descendant(of: find.byType(ReactionBar), matching: find.text(emoji))
        .evaluate()
        .length;

/// The app's tests run with animations turned off, which makes reactions over in a flash; these watch them fly.
void moving(WidgetTester tester) =>
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
