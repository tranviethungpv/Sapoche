import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/frame_boost.dart';

void main() {
  /// Draws [count] frames [gapMs] apart by keeping something animating.
  Future<void> frames(WidgetTester tester, int count, int gapMs) async {
    for (var i = 0; i < count; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await tester.pump(Duration(milliseconds: gapMs));
    }
  }

  testWidgets(
    'asks for the fastest rate while frames follow one another, and gives it back when they stop',
    (tester) async {
      final calls = <bool>[];
      final boost = FrameBoost(
        calls.add,
        idle: const Duration(milliseconds: 300),
      )..start();
      addTearDown(boost.dispose);

      await frames(tester, 10, 8);
      expect(calls, [true]);
      expect(boost.boosted, isTrue);

      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, [true, false]);
      expect(boost.boosted, isFalse);
    },
  );

  testWidgets('a few frames a second are not movement', (tester) async {
    final calls = <bool>[];
    final boost = FrameBoost(calls.add)..start();
    addTearDown(boost.dispose);
    // A seek bar moves five times a second, the bars of the equalizer ten
    await frames(tester, 20, 200);
    await frames(tester, 20, 100);
    expect(calls, isEmpty);
  });

  testWidgets('three frames in a row are not yet movement, four are', (
    tester,
  ) async {
    final calls = <bool>[];
    final boost = FrameBoost(calls.add)..start();
    addTearDown(boost.dispose);
    await frames(tester, 3, 16);
    expect(calls, isEmpty);
    await frames(tester, 2, 16);
    expect(calls, [true]);
    await tester.pump(const Duration(seconds: 1)); // the quiet time runs out
  });

  testWidgets(
    'goes on holding the rate while the movement goes on, and takes it only once',
    (tester) async {
      final calls = <bool>[];
      final boost = FrameBoost(
        calls.add,
        idle: const Duration(milliseconds: 300),
      )..start();
      addTearDown(boost.dispose);
      await frames(
        tester,
        30,
        16,
      ); // about half a second, longer than the quiet time
      expect(calls, [true]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, [true, false]);
    },
  );

  testWidgets('a second movement asks again', (tester) async {
    final calls = <bool>[];
    final boost = FrameBoost(calls.add, idle: const Duration(milliseconds: 100))
      ..start();
    addTearDown(boost.dispose);
    await frames(tester, 8, 8);
    await tester.pump(const Duration(milliseconds: 300));
    await frames(tester, 8, 8);
    expect(calls, [true, false, true]);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('gives the rate back when the app goes away during a movement', (
    tester,
  ) async {
    final calls = <bool>[];
    final boost = FrameBoost(calls.add)..start();
    await frames(tester, 8, 8);
    expect(calls, [true]);
    boost.dispose();
    expect(calls, [true, false]);
  });
}
