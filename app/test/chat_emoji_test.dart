import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/chat_emoji.dart';

import 'chat_test.dart' show history, message;
import 'fake_backend.dart';
import 'pump_app.dart';

void main() {
  group('emojiOnly', () {
    test('counts one to three emoji and nothing else', () {
      expect(emojiOnly('😂'), 1);
      expect(emojiOnly(' 😂 '), 1);
      expect(emojiOnly('😂🔥'), 2);
      expect(emojiOnly('😂 🔥❤️'), isNull, reason: 'a space is not an emoji');
      expect(emojiOnly('😂🔥❤️'), 3);
      expect(emojiOnly('😂🔥❤️👍'), isNull);
    });

    test(
      'takes the joined and tinted forms, flags and keycaps as one each',
      () {
        expect(emojiOnly('👨‍👩‍👧‍👦'), 1);
        expect(emojiOnly('👍🏽'), 1);
        expect(emojiOnly('🇻🇳'), 1);
        expect(emojiOnly('1️⃣'), 1);
      },
    );

    test('leaves words, digits and symbols alone', () {
      expect(emojiOnly(''), isNull);
      expect(emojiOnly('hi'), isNull);
      expect(emojiOnly('hi 😂'), isNull);
      expect(emojiOnly('1'), isNull);
      expect(emojiOnly('123'), isNull);
      expect(emojiOnly('#'), isNull);
      expect(emojiOnly('*'), isNull);
    });

    test('the fewer emoji, the bigger', () {
      expect(bigEmojiSize(1), 48);
      expect(bigEmojiSize(2), 40);
      expect(bigEmojiSize(3), 32);
    });
  });

  testWidgets(
    'a message of emoji only has no bubble, a message with words has one',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        history([message(1, 'b', '😂'), message(2, 'me', 'hello 😂')]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();

      final big = find.byKey(const ValueKey('chat-big-emoji'));
      expect(big, findsOneWidget);
      expect(tester.widget<Text>(big).style?.fontSize, 48);
      expect(
        find.ancestor(
          of: big,
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration != null,
          ),
        ),
        findsNothing,
      );
      expect(find.text('hello 😂'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('hello 😂'),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration != null,
          ),
        ),
        findsOneWidget,
      );
    },
  );
}
