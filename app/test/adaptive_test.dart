import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/player/lyrics_view.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';
import 'package:sapoche/ui/widgets/track_menu.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// Opens the app at [width] x [height] dp with a song playing, on the home page.
Future<FakeBackend> pumpAt(
  WidgetTester tester,
  double width,
  double height,
) async {
  final (backend, _) = await pumpApp(tester, listen: false);
  backend.emit(StateEvent(sampleRoom()));
  backend.emit(
    const PositionEvent(
      PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
    ),
  );
  await resize(tester, width, height);
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull);
  return backend;
}

const songA = Track(
  videoId: 'aaaaaaaaaaa',
  title: 'Alpha',
  artist: 'Ann',
  durMs: 200000,
);
const songB = Track(
  videoId: 'bbbbbbbbbbb',
  title: 'Beta',
  artist: 'Ben',
  durMs: 180000,
);

ShellLayout layoutOf(WidgetTester tester) =>
    HomeShell.layoutOf(tester.element(find.byType(HomeShell)));

void main() {
  group('the layout follows the width of the window', () {
    for (final (width, height, layout) in [
      (390.0, 844.0, ShellLayout.bars),
      (844.0, 390.0, ShellLayout.bars),
      (599.0, 900.0, ShellLayout.bars),
      (820.0, 1180.0, ShellLayout.rail),
      (1280.0, 800.0, ShellLayout.sidebar),
      (1920.0, 1080.0, ShellLayout.sidebar),
    ]) {
      testWidgets('${width}x$height is $layout', (tester) async {
        await pumpAt(tester, width, height);
        expect(layoutOf(tester), layout);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('beside a rail', () {
    testWidgets('the tabs are in a column on the left and open pages', (
      tester,
    ) async {
      await pumpAt(tester, 820, 1180);
      final home = tester.getRect(find.text(S.tabHome));
      final listen = tester.getRect(find.text(S.tabListen));
      expect(home.left, lessThan(100));
      expect(listen.top, greaterThan(home.top));
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.text(S.tabListen));
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the mini player floats clear of the rail, within the screen', (
      tester,
    ) async {
      await pumpAt(tester, 820, 1180);
      final mini = tester.getRect(find.byType(MiniPlayer));
      expect(mini.left, greaterThan(100));
      expect(mini.right, lessThanOrEqualTo(820));
      expect(mini.bottom, lessThanOrEqualTo(1180));
      expect(mini.width, lessThanOrEqualTo(520));
    });
  });

  group('beside a sidebar', () {
    testWidgets('has the search field, the tabs and the playlists', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      expect(find.text(S.tabSearch), findsWidgets);
      expect(find.text(S.tabLibrary), findsWidgets);
      expect(find.text(S.likedSongs), findsOneWidget);
      expect(find.text(S.downloadedSongs), findsOneWidget);
      expect(find.byType(PlayerBar), findsOneWidget);
      expect(find.byType(MiniPlayer), findsNothing);
    });

    testWidgets('a liked-songs row opens that list of the library', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(find.text(S.likedSongs));
      await tester.pumpAndSettle();
      // Its title, and the row of the sidebar that opened it
      expect(find.text(S.likedSongs), findsNWidgets(2));
      expect(find.byTooltip(S.downloadAll), findsNothing);
    });

    testWidgets('the player bar runs along the bottom, right of the sidebar', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      final bar = tester.getRect(find.byType(PlayerBar));
      expect(bar.left, greaterThan(250));
      expect(bar.right, lessThanOrEqualTo(1280));
      expect(bar.bottom, lessThanOrEqualTo(800));
      expect(bar.height, PlayerBar.height);
    });

    testWidgets('the bar opens the player, and its lyrics button the lyrics', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(find.byTooltip(S.lyrics));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(LyricsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the bar opens the player on the cover', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Song 0'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(LyricsView), findsNothing);
      expect(find.byTooltip(S.close), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape closes the player', (tester) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Song 0'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byTooltip(S.close), findsNothing);
    });

    testWidgets('settings show a topic beside the list', (tester) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(find.byTooltip(S.settingsTitle));
      await tester.pumpAndSettle();
      // The list, and the topic that is open beside it
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-system')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('language-vi')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-system')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('keys', () {
    testWidgets('Space plays or pauses', (tester) async {
      final backend = await pumpAt(tester, 1280, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.calls, contains('pause'));
    });

    testWidgets('the slash key opens Search with the cursor in the field', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });
  });

  group('a mouse and a remote', () {
    testWidgets('a right click on a song opens its menu', (tester) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.likedSongs = [songA, songB];
      backend.emit(const StateEvent(RoomSnapshot()));
      await resize(tester, 1280, 800);
      await tester.tap(find.text(S.likedSongs));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      // The sidebar row and the list's own title both read this; the list's rows are what the menu is for
      expect(find.byType(TrackMenu), findsWidgets);
      await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text(S.playNext), findsOneWidget);
      expect(find.text(S.addToQueue), findsOneWidget);
    });

    testWidgets('the arrows of a remote move the focus from row to row', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      // Tab goes to the gear at the top of the page, then to the sidebar's first row; the arrows walk down its column
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final seen = <FocusNode?>{FocusManager.instance.primaryFocus};
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        seen.add(FocusManager.instance.primaryFocus);
      }
      // The sidebar's rows are in a column: the arrows go down it, one row at a time
      expect(seen.whereType<FocusNode>().length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('the pages in a big window', () {
    testWidgets('1920x1080: every tab opens without an overflow', (
      tester,
    ) async {
      await pumpAt(tester, 1920, 1080);
      for (final tab in [S.tabLibrary, S.tabListen, S.tabHome]) {
        await tester.tap(find.text(tab).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });

    testWidgets('home keeps to a readable width in the middle', (tester) async {
      await pumpAt(tester, 1920, 1080);
      await tester.tap(find.text(S.tabHome).first);
      await tester.pumpAndSettle();
      final title = tester.getRect(
        find.text(S.goodMorning).evaluate().isEmpty
            ? find.text(S.goodAfternoon).evaluate().isEmpty
                  ? find.text(S.goodEvening)
                  : find.text(S.goodAfternoon)
            : find.text(S.goodMorning),
      );
      // The page is 1180 wide in the middle of what is left of the sidebar: its title is not at the sidebar's edge
      expect(title.left, greaterThan(300));
    });
  });
}
