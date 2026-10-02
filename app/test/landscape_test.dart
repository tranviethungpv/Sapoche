import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:unison/strings.dart';
import 'package:unison/ui/home_shell.dart';
import 'package:unison/ui/player/lyrics_view.dart';
import 'package:unison/ui/player/up_next_view.dart';
import 'package:unison/ui/player_sheet.dart';
import 'package:unison/ui/widgets/marquee_text.dart';
import 'package:unison/ui/widgets/mini_player.dart';
import 'package:unison/ui/widgets/playback_bar.dart';

import 'fake_backend.dart';
import 'player_panels_test.dart' show openPanel, openPlayer;
import 'pump_app.dart';

/// Turns the window to [width] x [height] dp, as the phone is turned or another one is held.
Future<void> resize(WidgetTester tester, double width, double height) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Rect inside(WidgetTester tester, double width, double height, Finder finder) {
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$finder, left');
  expect(rect.top, greaterThanOrEqualTo(-0.5), reason: '$finder, top');
  expect(rect.right, lessThanOrEqualTo(width + 0.5), reason: '$finder, right');
  expect(
    rect.bottom,
    lessThanOrEqualTo(height + 0.5),
    reason: '$finder, bottom',
  );
  return rect;
}

void main() {
  group('the player on its side', () {
    // iPhone 14 Pro, iPhone SE and two short Android screens, then an upright phone as the control
    for (final (width, height) in [
      (844.0, 390.0),
      (667.0, 375.0),
      (800.0, 360.0),
      (390.0, 844.0),
    ]) {
      testWidgets('${width}x$height: nothing overlaps or leaves the screen', (
        tester,
      ) async {
        await openPlayer(tester, snapshot: sampleRoom());
        await resize(tester, width, height);
        expect(tester.takeException(), isNull);

        final cover = inside(tester, width, height, find.byType(CoverSlot));
        final bar = inside(tester, width, height, find.byType(PlaybackBar));
        final lyrics = inside(tester, width, height, find.byTooltip(S.lyrics));
        inside(tester, width, height, find.byTooltip(S.upNext));
        expect(cover.overlaps(bar), isFalse, reason: 'cover and seek bar');
        expect(cover.overlaps(lyrics), isFalse, reason: 'cover and toolbar');
        expect(
          bar.bottom,
          lessThan(lyrics.top + 1),
          reason: 'bar above toolbar',
        );
      });
    }

    testWidgets('the cover is on the left and the controls on the right', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 844, 390);
      final cover = tester.getRect(find.byType(CoverSlot));
      final bar = tester.getRect(find.byType(PlaybackBar));
      expect(cover.right, lessThan(bar.left));
      // As tall as the screen allows, not the 140 dp a squeezed column left it
      expect(cover.height, greaterThan(300));
      expect(find.byTooltip(S.close), findsOneWidget);
    });

    testWidgets('the room strip fits too', (tester) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 667, 375);
      expect(tester.takeException(), isNull);
      final bottom = tester.getRect(find.byTooltip(S.lyrics)).bottom;
      expect(bottom, lessThan(375));
    });

    testWidgets('the arrow closes the player', (tester) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 844, 390);
      await tester.tap(find.byTooltip(S.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(PlaybackBar), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);
    });

    testWidgets('the lyrics take the place of the controls, beside the cover', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 844, 390);
      await openPanel(tester, S.lyrics);
      expect(tester.takeException(), isNull);
      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(PlaybackBar), findsNothing);
      // The cover stays, and the song can still be played and skipped
      expect(find.byType(CoverSlot), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      // The same button again goes back to the controls
      await openPanel(tester, S.lyrics);
      expect(find.byType(PlaybackBar), findsOneWidget);
      expect(find.byType(LyricsView), findsNothing);
    });

    testWidgets('turning the phone keeps the panel that is open', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await openPanel(tester, S.upNext);
      await resize(tester, 844, 390);
      expect(tester.takeException(), isNull);
      expect(find.byType(PlaybackBar), findsNothing);
      expect(find.byType(UpNextView), findsOneWidget);
      await resize(tester, 390, 844);
      expect(tester.takeException(), isNull);
      expect(find.byType(UpNextView), findsOneWidget);
    });

    testWidgets('a video gets a place of its own beside the controls', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom(video: true));
      await resize(tester, 844, 390);
      expect(tester.takeException(), isNull);
      final bar = inside(tester, 844, 390, find.byType(PlaybackBar));
      expect(bar.left, greaterThan(844 * 0.45));
    });
  });

  group('the mini player', () {
    testWidgets('scrolls a long title and artist instead of cutting them', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      // The close arrow is only in the layout on its side
      await resize(tester, 844, 390);
      await tester.tap(find.byTooltip(S.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.byType(MarqueeText),
        ),
        findsNWidgets(2),
      );
    });
  });

  group('the bars on their side', () {
    testWidgets('are lower, and lists clear them', (tester) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 844, 390);
      await tester.tap(find.byTooltip(S.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(MiniPlayer)).height, 52);
      final context = tester.element(find.byType(HomeShell));
      expect(HomeShell.bottomInsetOf(context), lessThan(176));
      // Nothing of the bars is out of the window
      expect(tester.getRect(find.byType(MiniPlayer)).bottom, lessThan(390));
      // And upright they are what they were
      await resize(tester, 390, 844);
      expect(tester.getSize(find.byType(MiniPlayer)).height, 58);
    });
  });

  group('the version', () {
    testWidgets('is in small print at the foot of the settings', (
      tester,
    ) async {
      PackageInfo.setMockInitialValues(
        appName: 'Unison',
        packageName: 'app.unison',
        version: '1.4.1',
        buildNumber: '12',
        buildSignature: '',
      );
      await pumpApp(tester);
      await openSettingsList(tester);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-version')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Unison 1.4.1 (12)'), findsOneWidget);
    });
  });
}
