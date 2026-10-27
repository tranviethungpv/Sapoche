import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';
import 'package:sapoche/ui/widgets/toast_layout.dart';

import 'pump_app.dart';

Future<Rect> toast(WidgetTester tester, Size window) async {
  await pumpApp(tester);
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  await tester.pump();
  ScaffoldMessenger.of(tester.element(find.byType(HomeShell)))
      .showSnackBar(const SnackBar(content: Text('Added to the queue')));
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  // The snack bar widget fills the scaffold, margin and all; the box people see is its Material
  final background = Theme.of(tester.element(find.byType(SnackBar)))
      .snackBarTheme
      .backgroundColor;
  return tester.getRect(
    find.descendant(
      of: find.byType(SnackBar),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.color == background,
      ),
    ),
  );
}

void main() {
  group('A toast', () {
    testWidgets('spans a phone, as Material has it', (tester) async {
      final rect = await toast(tester, const Size(390, 844));
      expect(rect.left, 15);
      expect(rect.right, 375);
    });

    testWidgets('keeps to a readable width in a big window', (tester) async {
      final rect = await toast(tester, const Size(1600, 900));
      expect(rect.width, ToastLayout.maxWidth);
      expect(rect.center.dx, 800);
    });

    testWidgets('floats above the player bar where it lies along the bottom', (
      tester,
    ) async {
      final rect = await toast(tester, const Size(1600, 900));
      expect(rect.bottom, lessThanOrEqualTo(900 - 12 - PlayerBar.height));
    });
  });
}
