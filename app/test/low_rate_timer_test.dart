import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/ui/widgets/low_rate_timer.dart';

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
}
