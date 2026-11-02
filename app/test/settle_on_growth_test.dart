import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/settle_on_growth_physics.dart';

Widget _list(ScrollController controller, ScrollPhysics physics, double tail) =>
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: ListView(
        controller: controller,
        physics: physics,
        children: [
          for (var i = 0; i < 10; i++) const SizedBox(height: 200),
          SizedBox(height: tail),
        ],
      ),
    );

/// Pulls a list past its end and lets go; with [grow], its last row gets taller once the spring is on its way back, as
/// the home page's does when a row that waited for the network gets its answer. Gives where the list ends up, from its
/// end.
Future<double> _pulledPastTheEnd(
  WidgetTester tester,
  ScrollPhysics physics, {
  required bool grow,
}) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(_list(controller, physics, 0));
  // Rows not yet drawn are guessed at, so the end is only known once the list has been there
  controller.jumpTo(controller.position.maxScrollExtent);
  await tester.pumpAndSettle();
  final end = controller.position.maxScrollExtent;
  expect(controller.position.pixels, end);
  final gesture = await tester.startGesture(const Offset(200, 300));
  for (var i = 0; i < 10; i++) {
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(controller.position.pixels, greaterThan(end));
  await gesture.up();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (grow) await tester.pumpWidget(_list(controller, physics, 800));
  await tester.pumpAndSettle();
  return controller.position.pixels - end;
}

void main() {
  testWidgets('a spring-back that new rows overtake flies up the list', (
    tester,
  ) async {
    final moved = await _pulledPastTheEnd(
      tester,
      const BouncingScrollPhysics(),
      grow: true,
    );
    expect(moved, lessThan(-100));
  });

  testWidgets('a list that grows under its spring-back stays where it is', (
    tester,
  ) async {
    final moved = await _pulledPastTheEnd(
      tester,
      SettleOnGrowthPhysics(parent: const BouncingScrollPhysics()),
      grow: true,
    );
    expect(moved, inInclusiveRange(0, 150));
  });

  testWidgets('a list that does not grow still springs back to its end', (
    tester,
  ) async {
    final moved = await _pulledPastTheEnd(
      tester,
      SettleOnGrowthPhysics(parent: const BouncingScrollPhysics()),
      grow: false,
    );
    expect(moved, 0);
  });
}
