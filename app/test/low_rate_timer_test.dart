import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/ui/widgets/low_rate_timer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ticks only while switched on and the app is on screen', (
    tester,
  ) async {
    var ticks = 0;
    final timer = LowRateTimer(
      const Duration(milliseconds: 100),
      () => ticks++,
    );
    addTearDown(timer.dispose);

    await tester.pump(const Duration(milliseconds: 350));
    expect(ticks, 0, reason: 'switched off');

    timer.run(true);
    await tester.pump(const Duration(milliseconds: 350));
    expect(ticks, 3);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 3, reason: 'in the background it stays silent');
    expect(timer.isRunning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    expect(ticks, 5, reason: 'and picks up again on return');

    timer.run(false);
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 5);
  });

  testWidgets('goes at half the pace while the phone is warm, and back after', (
    tester,
  ) async {
    addTearDown(() => Calm.on.value = false);
    var ticks = 0;
    final timer = LowRateTimer(
      const Duration(milliseconds: 100),
      () => ticks++,
    );
    addTearDown(timer.dispose);
    timer.run(true);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(ticks, 10);

    Calm.on.value = true;
    ticks = 0;
    await tester.pump(const Duration(milliseconds: 1000));
    expect(ticks, 5, reason: 'warm: one tick in 200 ms');

    Calm.on.value = false;
    ticks = 0;
    await tester.pump(const Duration(milliseconds: 1000));
    expect(ticks, 10);
    timer.run(false); // a timer left running would outlive the test
  });

  testWidgets('a timer that was switched off stays off when the pace changes', (
    tester,
  ) async {
    addTearDown(() => Calm.on.value = false);
    var ticks = 0;
    final timer = LowRateTimer(
      const Duration(milliseconds: 100),
      () => ticks++,
    );
    addTearDown(timer.dispose);
    Calm.on.value = true;
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 0);
    expect(timer.isRunning, isFalse);
  });
}
