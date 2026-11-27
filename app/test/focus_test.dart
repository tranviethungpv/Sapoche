import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/tv/tv.dart' show TvScope;
import 'package:sapoche/ui/widgets/focus_nav.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'player_panels_test.dart' show openPanel, openPlayer;
import 'pump_app.dart';

/// Opens the app with a song playing in a window of [width] x [height] dp, as a TV remote would see it: no touch.
Future<FakeBackend> pumpForKeys(
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
  return backend;
}

Rect? focused() => FocusManager.instance.primaryFocus?.rect;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group(
    'the arrows of a remote go between the tabs, the page and the player',
    () {
      testWidgets(
        'left reaches the sidebar, right comes back to the same control',
        (tester) async {
          await pumpForKeys(tester, 1280, 800);
          // The first press lands on the page
          await press(tester, LogicalKeyboardKey.arrowDown);
          final start = focused();
          expect(start, isNotNull);
          expect(
            start!.left,
            greaterThan(280),
            reason: 'the page, not the sidebar',
          );
          // Left until the edge of the page, then the sidebar
          var tries = 0;
          while (focused()!.left > 280 && tries++ < 30) {
            await press(tester, LogicalKeyboardKey.arrowLeft);
          }
          expect(focused()!.left, lessThan(280), reason: 'in the sidebar');
          // Right again: back on the page
          await press(tester, LogicalKeyboardKey.arrowRight);
          expect(focused()!.left, greaterThan(280));
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('right from the page reaches the player beside it', (
        tester,
      ) async {
        await pumpForKeys(tester, 1280, 800);
        await press(tester, LogicalKeyboardKey.arrowDown);
        var tries = 0;
        while (focused()!.left < 1280 - 440 && tries++ < 60) {
          await press(tester, LogicalKeyboardKey.arrowRight);
        }
        expect(focused()!.left, greaterThanOrEqualTo(1280 - 440 - 1));
        // And back to the page
        tries = 0;
        while (focused()!.left > 1280 - 440 - 20 && tries++ < 30) {
          await press(tester, LogicalKeyboardKey.arrowLeft);
        }
        expect(focused()!.right, lessThan(1280 - 400));
        expect(tester.takeException(), isNull);
      });

      testWidgets('down from the page of a phone reaches the tabs', (
        tester,
      ) async {
        await pumpForKeys(tester, 390, 844);
        await press(tester, LogicalKeyboardKey.arrowDown);
        var tries = 0;
        while (focused()!.top < 844 - 200 && tries++ < 60) {
          await press(tester, LogicalKeyboardKey.arrowDown);
        }
        expect(focused()!.top, greaterThan(844 - 200));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Back from the page goes to the tabs before it leaves', (
        tester,
      ) async {
        await pumpForKeys(tester, 1280, 800);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused()!.left, greaterThan(280));
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 100));
        expect(focused()!.left, lessThan(280), reason: 'on the tabs');
      });
    },
  );

  group('the keys of a remote', () {
    testWidgets('play/pause, next and previous reach the player', (
      tester,
    ) async {
      final backend = await pumpForKeys(tester, 1280, 800);
      await press(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(backend.calls, contains('pause'));
      await press(tester, LogicalKeyboardKey.mediaTrackNext);
      expect(backend.calls, contains('next'));
      await press(tester, LogicalKeyboardKey.mediaTrackPrevious);
      expect(backend.calls, contains('prev'));
    });
  });

  group('what a long press does for a finger, a remote does by holding OK', () {
    testWidgets(
      'a short OK is a tap, a long one and the Menu key open the menu',
      (tester) async {
        var taps = 0;
        var menus = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Material(
              child: Center(
                child: MenuKeys(
                  onMenu: () => menus++,
                  child: InkWell(
                    autofocus: true,
                    onTap: () => taps++,
                    child: const SizedBox(width: 120, height: 48),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect((taps, menus), (1, 0), reason: 'let go at once: a tap');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.pump(MenuKeys.hold + const Duration(milliseconds: 50));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect(
          (taps, menus),
          (1, 1),
          reason: 'held: the menu, and no tap after',
        );

        // Android's own word that it was held: the repeat that comes after the long-press time
        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect((taps, menus), (1, 2), reason: 'a repeat is a hold');

        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
        expect(menus, 4);
      },
    );

    testWidgets('a row of the queue has up, down, next and remove in a menu', (
      tester,
    ) async {
      final backend = await openPlayer(tester, snapshot: sampleRoom(songs: 4));
      await openPanel(tester, 'Up next');
      // The nearest Focus over the title is the row's own
      Focus.of(tester.element(find.text('Song 2').first)).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(MenuKeys.hold + const Duration(milliseconds: 50));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text(S.moveUp), findsOneWidget);
      expect(find.text(S.moveDown), findsOneWidget);
      expect(find.text(S.removeFromQueue), findsOneWidget);
      await tester.tap(find.text(S.removeFromQueue));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('remove')), hasLength(1));
    });
  });

  group('a text field on a TV', () {
    Future<(FocusNode, bool Function())> pumpField(
      WidgetTester tester, {
      required bool tv,
    }) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvScope(
              on: tv,
              child: TvFieldGate(
                focusNode: node,
                builder: (n, readOnly) =>
                    TextField(focusNode: n, readOnly: readOnly),
              ),
            ),
          ),
        ),
      );
      return (
        node,
        () => tester.widget<TextField>(find.byType(TextField)).readOnly,
      );
    }

    testWidgets('is passed over with no keyboard, and OK opens it', (
      tester,
    ) async {
      final (node, readOnly) = await pumpField(tester, tv: true);
      node.requestFocus();
      await tester.pump();
      expect(readOnly(), isTrue, reason: 'focused by the arrows: not open');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(readOnly(), isFalse, reason: 'OK: open for typing');
      node.unfocus();
      await tester.pump();
      expect(readOnly(), isTrue, reason: 'left: closed again');
    });

    testWidgets('is an ordinary field off a TV', (tester) async {
      final (node, readOnly) = await pumpField(tester, tv: false);
      node.requestFocus();
      await tester.pump();
      expect(readOnly(), isFalse);
    });
  });
}
