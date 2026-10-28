import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/chat_sheet.dart';

import 'chat_test.dart' show history, message;
import 'fake_backend.dart';
import 'pump_app.dart';

/// A phone or a browser that can tell the person of the chat while the app is away, not asked yet.
const askable = NotificationInfo(supported: true);

void main() {
  group('the settings', () {
    testWidgets('have no notifications where the device cannot give them', (tester) async {
      await pumpApp(tester);
      await openSettingsList(tester);
      expect(find.byKey(const ValueKey('settings-notices')), findsNothing);
    });

    testWidgets('turn them on with a touch, and then offer to leave the text out of them', (tester) async {
      final (backend, _) = await pumpApp(tester, prepare: (b) => b.noticeInfo = askable);
      await openTopic(tester, 'notices');
      expect(find.byKey(const ValueKey('notices-preview')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('notices-switch')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('notifications true'));
      expect(find.byKey(const ValueKey('notices-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notices-preview')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('noticePreview false'));
    });

    testWidgets('say what to do when the device has them blocked, and let the switch be', (tester) async {
      await pumpApp(tester, prepare: (b) => b.noticeInfo = const NotificationInfo(supported: true, permission: NoticePermission.denied));
      await openTopic(tester, 'notices');
      expect(find.text(S.noticesDenied), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('notices-switch'))).onChanged, isNull);
    });

    testWidgets('say how to get them on an iPhone that has the page in a tab', (tester) async {
      await pumpApp(tester, prepare: (b) => b.noticeInfo = const NotificationInfo(supported: true, needsInstall: true));
      await openTopic(tester, 'notices');
      expect(find.text(S.noticesNeedInstall), findsOneWidget);
    });
  });

  group('the chat', () {
    Future<FakeBackend> chatOpen(WidgetTester tester, NotificationInfo info) async {
      final (backend, _) = await pumpApp(tester, prepare: (b) => b.noticeInfo = info);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(history([message(1, 'b', 'hi there')]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      expect(find.byType(ChatSheet), findsOneWidget);
      return backend;
    }

    testWidgets('offer the notices, and turning them on is one touch', (tester) async {
      final backend = await chatOpen(tester, askable);
      expect(find.text(S.noticesOffer), findsOneWidget);
      await tester.tap(find.text(S.noticesTurnOn));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('notifications true'));
      expect(find.text(S.noticesOffer), findsNothing);
      expect(find.byKey(const ValueKey('chat-mute')), findsOneWidget);
    });

    testWidgets('the offer steps aside while the keyboard is up, and is back when it goes', (tester) async {
      await chatOpen(tester, askable);
      expect(find.text(S.noticesOffer), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 800);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.text(S.noticesOffer), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text(S.noticesOffer), findsOneWidget);
    });

    testWidgets('do not offer them again for a week after "not now"', (tester) async {
      await chatOpen(tester, askable);
      await tester.tap(find.text(S.noticesNotNow));
      await tester.pumpAndSettle();
      expect(find.text(S.noticesOffer), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      expect(find.text(S.noticesOffer), findsNothing);
    });

    testWidgets('offer nothing to a device that blocks them or cannot show them', (tester) async {
      await chatOpen(tester, const NotificationInfo(supported: true, permission: NoticePermission.denied));
      expect(find.text(S.noticesOffer), findsNothing);
      expect(find.byKey(const ValueKey('chat-mute')), findsNothing);
    });

    testWidgets('keep the room quiet for a while, and turn it back on', (tester) async {
      final backend = await chatOpen(tester, const NotificationInfo(supported: true, permission: NoticePermission.granted, enabled: true));
      expect(find.text(S.noticesOffer), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-mute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.noticesMute8h));
      await tester.pumpAndSettle();
      final call = backend.calls.singleWhere((c) => c.startsWith('muteRoom'));
      final until = int.parse(call.split(' ').last);
      expect(until - DateTime.now().millisecondsSinceEpoch, closeTo(8 * 3600 * 1000, 5000));
      await tester.tap(find.byKey(const ValueKey('chat-mute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.noticesUnmute));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('muteRoom')).last, 'muteRoom ABC234 null');
    });
  });

  testWidgets('a touch on a notice of the room opens its chat', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    backend.emit(history([message(1, 'b', 'hi there')]));
    await tester.pumpAndSettle();
    expect(find.byType(ChatSheet), findsNothing);
    backend.emit(const OpenChatEvent('ABC234'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatSheet), findsOneWidget);
  });
}
