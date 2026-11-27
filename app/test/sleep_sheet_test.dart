import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/player/parts.dart';
import 'package:sapoche/ui/sleep_sheet.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'player_styles_test.dart' show openStyled;

void main() {
  // 22:30 now; the song is 200 s long and is at 4 s (openStyled)
  final now = DateTime(2026, 11, 27, 22, 30, 0);
  setUp(() => sleepNow = () => now);
  tearDown(() => sleepNow = DateTime.now);

  Future<FakeBackend> openSheet(WidgetTester tester) async {
    final backend = await openStyled(tester, PlayerStyle.classic);
    await tester.tap(find.byTooltip(S.sleepTimer));
    await tester.pumpAndSettle();
    return backend;
  }

  Finder text(String s) => find.text(s);

  testWidgets('every choice says the hour the music would stop at', (tester) async {
    await openSheet(tester);
    // 22:30 + 15 / 30 / 45 / 60 / 90 minutes
    for (final at in ['10:45 PM', '11:00 PM', '11:15 PM', '11:30 PM', '12:00 AM']) {
      expect(text(at), findsOneWidget, reason: at);
    }
    // No timer is set: no status block
    expect(find.byKey(const ValueKey('sleep-status')), findsNothing);
    // The end of the song: now + (200 s - 4 s) = 22:33:16
    expect(text(S.sleepAround('10:33 PM')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a timer in minutes shows its hour and what is left, and can be turned off', (tester) async {
    final backend = await openSheet(tester);
    backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: now.add(const Duration(minutes: 12)))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('sleep-status')), findsOneWidget);
    expect(text(S.sleepStatusAt('10:42 PM')), findsOneWidget);
    expect(text(S.sleepLeft(const Duration(minutes: 12))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sleep-off')));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('sleep off 0'));
  });

  testWidgets('under a minute it counts the seconds, and at the end of a song it counts from the position', (tester) async {
    final backend = await openSheet(tester);
    backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: now.add(const Duration(seconds: 40)))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(text(S.sleepLeft(const Duration(seconds: 40))), findsOneWidget);
    backend.emit(const SleepEvent(SleepState(mode: SleepMode.song)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(text(S.sleepStatusSong), findsOneWidget);
    expect(text(S.sleepLeft(const Duration(seconds: 196), clock: true)), findsOneWidget);
  });

  testWidgets('the sheet moves on with the clock', (tester) async {
    final backend = await openSheet(tester);
    backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: now.add(const Duration(minutes: 12)))));
    await tester.pump(const Duration(milliseconds: 50));
    sleepNow = () => now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(text(S.sleepLeft(const Duration(minutes: 11))), findsOneWidget);
    // The hours of the rows start from the new time
    expect(text('10:46 PM'), findsOneWidget);
  });

  testWidgets('the number of minutes typed says its hour', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('sleep-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '20');
    await tester.pump();
    expect(text(S.sleepStatusAt('10:50 PM')), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2000');
    await tester.pump();
    expect(find.textContaining(S.sleepStatusAt('')), findsNothing);
  });

  testWidgets('the "..." menu of the small player says the hour while one is set', (tester) async {
    final backend = await openStyled(tester, PlayerStyle.classic);
    await resize(tester, 844, 390);
    backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: now.add(const Duration(minutes: 30)))));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.descendant(of: find.byType(NowPlayingPage), matching: find.byType(PlayerMoreButton)));
    await tester.pumpAndSettle();
    expect(find.text(S.sleepTimerAt('11:00 PM')), findsOneWidget);
    expect(find.byIcon(Icons.bedtime_rounded), findsOneWidget);
  });
}
