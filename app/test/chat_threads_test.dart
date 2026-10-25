import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/queued_autoplay.dart';

import 'chat_test.dart' show arrived, history, message;
import 'fake_backend.dart';
import 'player_panels_test.dart' show openPanel, openPlayer;
import 'pump_app.dart';

ChatMessage reacted(ChatMessage m, Map<String, Reaction> reactions) =>
    ChatMessage(
      id: m.id,
      by: m.by,
      name: m.name,
      text: m.text,
      at: m.at,
      reactions: reactions,
    );

ChatEvent receiptsOf(Map<String, ChatReceipt> receipts) => ChatEvent(
  room: 'ABC234',
  messages: const [],
  replace: false,
  receipts: receipts,
);

/// A room whose queue is [user] songs the members chose and then [auto] that autoplay lined up.
RoomSnapshot roomWithAutoplay({int user = 2, int auto = 2, int index = 0}) {
  final base = sampleRoom(songs: user, index: index);
  return RoomSnapshot(
    room: base.room,
    link: base.link,
    you: base.you,
    phase: 'playing',
    index: index,
    members: base.members,
    roomAutoplay: true,
    queue: [
      ...base.queue,
      for (var i = 0; i < auto; i++)
        QueueEntry(
          id: 'auto$i',
          videoId: 'autovideo$i',
          title: 'Auto $i',
          artist: 'Radio',
          durMs: 180000,
          addedBy: 'b',
          auto: true,
        ),
    ],
  );
}

void main() {
  group('replies, reactions to a message, receipts in the controller', () {
    late FakeBackend backend;
    late RoomController controller;

    setUp(() async {
      backend = FakeBackend();
      controller = RoomController(backend);
      await controller.start();
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history([message(1, 'b', 'hi'), message(2, 'me', 'hello')]));
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() => controller.dispose());

    test('an answer goes with the number of the message it answers and keeps it', () async {
      final quote = ChatQuote(id: 1, by: 'b', name: 'Binh', text: 'hi');
      await controller.sendChat('yes', reply: quote);
      expect(backend.calls, contains('sendChat yes reply 1'));
      expect(controller.chat.value.last.reply?.text, 'hi');
      // Sent again, it is still an answer
      await controller.resendChat(controller.chat.value.last);
      expect(backend.calls.where((c) => c == 'sendChat yes reply 1'), hasLength(2));
    });

    test('a reaction to a message shows at once, goes to the room, and is taken back by the same one', () async {
      final target = controller.chat.value.first;
      controller.reactToMessage(target, Reaction.fire);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, contains('reactChat 1 fire'));
      expect(controller.chat.value.first.reactions, {'me': Reaction.fire});
      controller.reactToMessage(controller.chat.value.first, null);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, contains('reactChat 1 null'));
      expect(controller.chat.value.first.reactions, isEmpty);
    });

    test('what the room says of a message replaces it, and is no news', () async {
      final notices = <Notice>[];
      controller.notices.listen(notices.add);
      backend.emit(
        arrived(reacted(message(1, 'b', 'hi'), {'b': Reaction.laugh, 'me': Reaction.fire})),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.chat.value, hasLength(2));
      expect(controller.chat.value.first.reactions.length, 2);
      expect(controller.unreadChat.value, 0);
      expect(notices, isEmpty);
    });

    test('a message is parsed with its answer and its reactions, and an old one has neither', () {
      final parsed = ChatMessage.fromJson({
        'id': 4,
        'by': 'b',
        'name': 'Binh',
        'text': 'yes',
        'at': 9,
        're': {'id': 3, 'by': 'me', 'name': 'Anna', 'text': 'hi'},
        'rx': {'me': 'fire', 'b': '🍕', 'c': 'not an emoji'},
      });
      expect(parsed.reply?.id, 3);
      expect(parsed.reactions.length, 2);
      expect(parsed.reactions['b']?.emoji, '🍕');
      final old = ChatMessage.fromJson({'id': 1, 'by': 'b', 'name': 'Binh', 'text': 'hi', 'at': 1});
      expect(old.reply, isNull);
      expect(old.reactions, isEmpty);
    });

    test('how far a message has come follows what the others have got', () async {
      await controller.sendChat('hello again');
      expect(controller.progressOf(controller.chat.value.last).stage, ChatStage.sending);
      final cid = backend.lastChatCid;
      backend.emit(arrived(message(3, 'me', 'hello again', cid: cid)));
      await Future<void>.delayed(Duration.zero);
      final mine = controller.chat.value.last;
      expect(controller.progressOf(mine).stage, ChatStage.sent);

      backend.emit(receiptsOf({'b': const ChatReceipt(delivered: 3)}));
      await Future<void>.delayed(Duration.zero);
      expect(controller.progressOf(mine).stage, ChatStage.delivered);

      backend.emit(receiptsOf({'b': const ChatReceipt(delivered: 3, read: 2)}));
      await Future<void>.delayed(Duration.zero);
      expect(controller.progressOf(mine).stage, ChatStage.delivered);

      backend.emit(receiptsOf({'b': const ChatReceipt(delivered: 3, read: 3)}));
      await Future<void>.delayed(Duration.zero);
      final seen = controller.progressOf(mine);
      expect(seen.stage, ChatStage.seen);
      expect(seen.seenBy, ['Binh']);
      // This device's own receipt says nothing about its own message
      backend.emit(receiptsOf({'me': const ChatReceipt(delivered: 3, read: 3)}));
      await Future<void>.delayed(Duration.zero);
      expect(controller.progressOf(mine).stage, ChatStage.sent);
    });

    test('the pictures mark where each of the others stopped reading', () async {
      backend.emit(arrived(message(3, 'b', 'one more')));
      backend.emit(receiptsOf({
        'b': const ChatReceipt(delivered: 3, read: 3),
        'c': const ChatReceipt(delivered: 3, read: 2),
        'me': const ChatReceipt(delivered: 3, read: 3),
      }));
      await Future<void>.delayed(Duration.zero);
      final markers = controller.readMarkers(controller.chat.value);
      // Binh stopped at his own message, which says nothing; 'c' stopped at the second; this device is not marked
      expect(markers, {
        2: ['c'],
      });
    });

    test('what the person looks at is told to the room, once for each message', () async {
      expect(backend.calls, isNot(contains(startsWith('readChat'))));
      controller.setChatOpen(true);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.where((c) => c.startsWith('readChat')), ['readChat 2']);
      controller.setChatOpen(true);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.where((c) => c.startsWith('readChat')), hasLength(1));
      backend.emit(arrived(message(3, 'b', 'new')));
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.where((c) => c.startsWith('readChat')), ['readChat 2', 'readChat 3']);
      // With the chat closed nothing is told
      controller.setChatOpen(false);
      backend.emit(arrived(message(4, 'b', 'unseen')));
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.where((c) => c.startsWith('readChat')), hasLength(2));
    });
  });

  group('on screen', () {
    Future<(FakeBackend, RoomController)> roomWithChat(WidgetTester tester) async {
      final (backend, room) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history([message(1, 'b', 'hi there'), message(2, 'me', 'hello')]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      return (backend, room);
    }

    Finder field() => find.byKey(const ValueKey('chat-field'));

    testWidgets('sending leaves the keyboard up, from the button and from the key', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      await tester.showKeyboard(field());
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.enterText(field(), 'one');
      await tester.pump();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(backend.calls, contains('sendChat one'));
      bool focused() =>
          tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
      expect(tester.testTextInput.isVisible, isTrue, reason: 'the keyboard stayed after the button');
      expect(focused(), isTrue);

      await tester.enterText(field(), 'two');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(backend.calls, contains('sendChat two'));
      expect(tester.testTextInput.isVisible, isTrue, reason: 'the keyboard stayed after the key');
      expect(focused(), isTrue);
      await tester.pump(RoomController.chatDeliveryTimeout * 2);
    });

    testWidgets('a touch elsewhere still puts the keyboard away', (tester) async {
      await roomWithChat(tester);
      await tester.showKeyboard(field());
      bool focused() =>
          tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
      expect(focused(), isTrue);
      await tester.tap(find.byTooltip(S.reactMore));
      await tester.pump();
      expect(focused(), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('a touch on a message shows when it was sent, and another touch hides it', (tester) async {
      await roomWithChat(tester);
      expect(find.byKey(const ValueKey('chat-message-time')), findsNothing);
      await tester.tap(find.text('hi there'));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-message-time')), findsOneWidget);
      // Another message takes it over
      await tester.tap(find.text('hello'));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-message-time')), findsOneWidget);
      await tester.tap(find.text('hello'));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-message-time')), findsNothing);
    });

    testWidgets('a long touch offers a reply, which is shown above the field and goes with the message', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      await tester.longPress(find.text('hi there'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
      expect(find.text(S.chatReplyingTo('Binh')), findsOneWidget);

      await tester.enterText(field(), 'what do you mean');
      await tester.pump();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(backend.calls, contains('sendChat what do you mean reply 1'));
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
      // The answer shows what it answers
      expect(find.byKey(const ValueKey('chat-quote')), findsOneWidget);
      await tester.pump(RoomController.chatDeliveryTimeout * 2);
    });

    testWidgets('the banner of a reply can be dropped', (tester) async {
      await roomWithChat(tester);
      await tester.longPress(find.text('hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-reply')));
      await tester.pumpAndSettle();
      expect(find.text(S.chatReplyingToYourself), findsOneWidget);
      await tester.tap(find.byTooltip(S.chatCancelReply));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
    });

    testWidgets('dragging a message sideways answers it', (tester) async {
      await roomWithChat(tester);
      await tester.drag(find.text('hi there'), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
      // A short drag does not
      await tester.tap(find.byTooltip(S.chatCancelReply));
      await tester.pump();
      await tester.drag(find.text('hi there'), const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
      // This device's own go the other way
      await tester.drag(find.text('hello'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsOneWidget);
    });

    testWidgets('a reaction picked from the menu shows under the message and is sent; a second one takes it away', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      await tester.longPress(find.text('hi there'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-react-fire')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('reactChat 1 fire'));
      expect(find.byKey(const ValueKey('chat-reactions')), findsOneWidget);
      expect(find.text('🔥'), findsWidgets);

      await tester.longPress(find.text('hi there'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-react-fire')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('reactChat 1 null'));
      expect(find.byKey(const ValueKey('chat-reactions')), findsNothing);
    });

    testWidgets('who reacted is told in the menu', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      backend.emit(arrived(reacted(message(1, 'b', 'hi there'), {'b': Reaction.laugh})));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reactions')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-reactions')));
      await tester.pumpAndSettle();
      expect(find.text(S.chatReactions), findsOneWidget);
      expect(find.text('Binh'), findsWidgets);
    });

    testWidgets('a message that was not sent offers only a copy', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      backend.chatConnected = false;
      await tester.enterText(field(), 'lost');
      await tester.pump();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      await tester.longPress(find.text('lost'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('message-reply')), findsNothing);
      expect(find.byKey(const ValueKey('message-react-fire')), findsNothing);
    });

    testWidgets('under this device’s last message: sent, then delivered, then seen', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      String status() => tester
          .widget<Row>(find.byKey(const ValueKey('chat-receipt')))
          .children
          .whereType<Text>()
          .map((t) => t.data)
          .join();
      expect(status(), S.chatSent);

      backend.emit(receiptsOf({'b': const ChatReceipt(delivered: 2)}));
      await tester.pumpAndSettle();
      expect(status(), S.chatDelivered);

      backend.emit(receiptsOf({'b': const ChatReceipt(delivered: 2, read: 2)}));
      await tester.pumpAndSettle();
      // Two in the room: the other one has seen it
      expect(status(), S.chatSeen);
      expect(find.byKey(const ValueKey('chat-receipt')), findsOneWidget);
    });

    testWidgets('while sending, the line says so; after a new message of this device’s own the line moves down', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      await tester.enterText(field(), 'next one');
      await tester.pump();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(find.text(S.chatSending), findsOneWidget);
      expect(find.text(S.chatSent), findsNothing);
      backend.emit(arrived(message(3, 'me', 'next one', cid: backend.lastChatCid)));
      await tester.pumpAndSettle();
      expect(find.text(S.chatSent), findsOneWidget);
      expect(find.text(S.chatSending), findsNothing);
    });

    testWidgets('the room is told what the person looks at only while the app is shown', (tester) async {
      final (backend, _) = await roomWithChat(tester);
      expect(backend.calls, contains('readChat 2'));
      void goTo(List<AppLifecycleState> steps) {
        for (final step in steps) {
          tester.binding.handleAppLifecycleStateChanged(step);
        }
      }

      goTo([
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      backend.emit(arrived(message(3, 'b', 'while away')));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('readChat 3')));
      goTo([
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('readChat 3'));
    });
  });

  group('autoplay songs stay apart from the queue', () {
    test('the members’ songs and the lined up ones are told apart', () {
      final snapshot = roomWithAutoplay(user: 3, auto: 2);
      expect(snapshot.upNext.map((e) => e.title), ['Song 1', 'Song 2']);
      expect(snapshot.autoUpNext.map((e) => e.title), ['Auto 0', 'Auto 1']);
      expect(snapshot.queue.last.auto, isTrue);
    });

    test('a member may add a song autoplay lined up, the one that plays still counts as queued', () {
      final snapshot = roomWithAutoplay(user: 2, auto: 2, index: 0);
      expect(snapshot.isQueued(snapshot.queue[1]), isTrue);
      expect(snapshot.isQueued(snapshot.queue[2]), isFalse);
      final lined = snapshot.queue[2];
      expect(snapshot.fresh([lined]), [lined]);
      // Playing an autoplay song: it counts, the next ones still do not
      final inside = roomWithAutoplay(user: 2, auto: 3, index: 2);
      expect(inside.isQueued(inside.queue[2]), isTrue);
      expect(inside.isQueued(inside.queue[3]), isFalse);
    });

    test('an item is parsed with its mark, and an older server sends none', () {
      expect(
        QueueEntry.fromJson({'id': 'q', 'videoId': 'v', 'title': 'T', 'addedBy': 'b', 'auto': true}).auto,
        isTrue,
      );
      expect(QueueEntry.fromJson({'id': 'q', 'videoId': 'v', 'title': 'T', 'addedBy': 'b'}).auto, isFalse);
    });

    testWidgets('Up Next keeps them in a section of their own, not in the queue', (tester) async {
      await openPlayer(tester, snapshot: roomWithAutoplay(user: 3, auto: 2));
      await openPanel(tester, 'Up Next');
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.byType(QueuedAutoplay), findsOneWidget);
      expect(find.descendant(of: find.byType(QueuedAutoplay), matching: find.text('Auto 0')), findsOneWidget);
      expect(find.descendant(of: find.byType(QueuedAutoplay), matching: find.text('Song 1')), findsNothing);
      expect(find.text(S.roomAutoplayQueued), findsOneWidget);
    });

    testWidgets('a touch on one plays it now', (tester) async {
      final backend = await openPlayer(tester, snapshot: roomWithAutoplay(user: 2, auto: 2));
      await openPanel(tester, 'Up Next');
      await tester.tap(find.text('Auto 1'));
      await tester.pump();
      expect(backend.calls.last, 'jump auto1');
    });

    testWidgets('without any, Up Next suggests as before', (tester) async {
      await openPlayer(tester, snapshot: sampleRoom(songs: 3).withRoomAutoplay());
      await openPanel(tester, 'Up Next');
      expect(find.byType(QueuedAutoplay), findsNothing);
    });
  });
}

extension on RoomSnapshot {
  RoomSnapshot withRoomAutoplay() => RoomSnapshot(
    room: room,
    link: link,
    you: you,
    phase: phase,
    index: index,
    members: members,
    queue: queue,
    roomAutoplay: true,
  );
}
