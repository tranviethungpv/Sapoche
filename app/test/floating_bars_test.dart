import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/widgets/glass.dart';
import 'package:sapoche/ui/widgets/transport.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// `docs/plans/2026-11-12-ui-fixed-yardstick.md` group A: the bars that float over the pages.
void main() {
  group('the card of the song on the Room page', () {
    Finder button() => find.descendant(
      of: find.byKey(const ValueKey('room-now-card')),
      matching: find.byType(PlayPauseButton),
    );

    testWidgets('has its own play button on a phone', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-now-card')), findsOneWidget);
      expect(button(), findsOneWidget);
    });

    testWidgets('has none in a wide window, where the player bar under the pages has the same one', (tester) async {
      final (backend, _) = await pumpApp(tester);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1280, 800);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-now-card')), findsOneWidget);
      expect(button(), findsNothing);
      // The bar still has it: one button to play and pause, not none
      expect(find.byType(PlayPauseButton), findsOneWidget);
    });
  });

  group('the glass of the bars', () {
    test('is solid while the phone is calm, so that nothing of the page is read under the bar', () {
      for (final p in [Palette.light, Palette.dark]) {
        expect(Glass.tintOf(p, calm: true).a, 1.0);
        expect(Glass.tintOf(p).a, lessThan(1.0));
      }
    });
  });
}
