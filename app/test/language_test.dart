import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/strings.dart';

import 'pump_app.dart';

void main() {
  tearDown(() => S.current = 'en');

  group('the texts', () {
    test('are in English until told otherwise', () {
      expect(S.tabHome, 'Home');
      expect(S.listening(2), '2 people listening');
    });

    test('follow the language, with the numbers and names in place', () {
      S.current = 'vi';
      expect(S.tabHome, 'Trang chủ');
      expect(S.listening(1), '1 người đang nghe');
      expect(S.addedBy('Ann'), 'Ann đã thêm');
      expect(S.ago(const Duration(minutes: 5)), '5 phút trước');
      expect(S.sleepMinutes(90), '1 giờ 30 phút');
      expect(
        S.backupSaved(3, 1, 0),
        'Đã lưu: 3 bài đã thích, 1 danh sách phát',
      );
      expect(S.playlistBy('Ann', 12), 'Ann · 12 bài');
    });

    test('keep English plurals right', () {
      expect(S.songCount(1), '1 song');
      expect(S.songCount(3), '3 songs');
    });

    test('say what the server refuses in both languages', () {
      for (final code in ['en', 'vi']) {
        S.current = code;
        for (final error in [
          'forbidden',
          'removed',
          'room_not_found',
          'room_full',
          'queue_full',
          'rate_limited',
        ]) {
          expect(S.serverError(error), isNotEmpty, reason: '$code $error');
        }
        expect(S.serverError('bad_json'), isNull);
      }
    });

    test('every language is named in itself', () {
      for (final code in S.languages) {
        expect(S.languageName(code), isNotEmpty);
      }
      expect(S.languageName('vi'), 'Tiếng Việt');
    });
  });

  group('the app', () {
    testWidgets('speaks the language that was chosen', (tester) async {
      final (backend, _) = await pumpApp(tester, prefs: {'language': 'vi'});
      expect(find.text('Trang chủ'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
      expect(backend.calls, contains('setLanguage vi'));
    });

    testWidgets('speaks the phone’s language when nothing was chosen', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('vi', 'VN')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pumpApp(tester);
      expect(find.text('Trang chủ'), findsOneWidget);
    });

    testWidgets('falls back to English for a language it does not have', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pumpApp(tester);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('a choice beats the phone’s language', (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('vi', 'VN')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pumpApp(tester, prefs: {'language': 'en'});
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('changes at once, on every page that is open', (tester) async {
      final (backend, _) = await pumpApp(tester);
      await openSettingsList(tester);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      expect(find.text('Tiếng Việt'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('language-vi')));
      await tester.pumpAndSettle();
      // This page, and the settings list and the tabs behind it, were all open
      expect(find.text('Ngôn ngữ'), findsWidgets);
      expect(find.text('Theo hệ thống'), findsWidgets);
      expect(backend.calls, contains('setLanguage vi'));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Giao diện'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-en')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('marks the language in use', (tester) async {
      await pumpApp(tester, prefs: {'language': 'vi'});
      await openSettingsList(tester);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('language-vi')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('language-en')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
    });

    testWidgets('lists the looks, marks the one in use and switches at once', (
      tester,
    ) async {
      await pumpApp(tester);
      await openSettingsList(tester);
      await tester.tap(find.byKey(const ValueKey('settings-appearance')));
      await tester.pumpAndSettle();
      Finder check(String mode) => find.descendant(
        of: find.byKey(ValueKey('theme-$mode')),
        matching: find.byIcon(Icons.check_rounded),
      );
      expect(check('light'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-dark')));
      await tester.pumpAndSettle();
      expect(check('dark'), findsOneWidget);
      expect(check('light'), findsNothing);
      expect(
        Theme.of(tester.element(find.byKey(const ValueKey('theme-dark'))))
            .brightness,
        Brightness.dark,
      );
    });

    testWidgets('the main pages fit in Vietnamese with large text', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, prefs: {'language': 'vi'});
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      for (final tab in ['Trang chủ', 'Tìm kiếm', 'Thư viện', 'Nghe']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
      await openSettingsList(tester);
      for (final topic in [
        'appearance',
        'language',
        'playback',
        'storage',
        'backup',
        'updates',
      ]) {
        await tester.tap(find.byKey(ValueKey('settings-$topic')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: topic);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      expect(backend.calls, isNotEmpty);
    });
  });
}
