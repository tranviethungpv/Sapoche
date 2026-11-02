import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/end_clamped_physics.dart';

Future<ScrollPosition> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: ListView(
        physics: const EndClampedPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        children: [for (var i = 0; i < 10; i++) const SizedBox(height: 200)],
      ),
    ),
  );
  return tester.state<ScrollableState>(find.byType(Scrollable)).position;
}

void main() {
  testWidgets('a list pulled past its end does not move past it', (
    tester,
  ) async {
    final position = await _pump(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final end = position.maxScrollExtent;
    final gesture = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, end);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, end);
  });

  testWidgets('a fling into the end stops at it', (tester) async {
    final position = await _pump(tester);
    await tester.fling(find.byType(ListView), const Offset(0, -600), 6000);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent));
    }
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('the top still bounces, which pulling to refresh needs', (
    tester,
  ) async {
    final position = await _pump(tester);
    final gesture = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, lessThan(-50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });
}
