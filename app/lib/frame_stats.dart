import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Profile builds only: prints how many frames missed their deadline, every few seconds while
/// frames are being drawn. Read it with `adb logcat -s flutter`.
void watchFrames() {
  if (!kProfileMode) return;
  var frames = 0, slow = 0;
  var worst = Duration.zero;
  final total = <int>[];
  var since = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final t in timings) {
      frames++;
      total.add(t.totalSpan.inMilliseconds);
      if (t.buildDuration.inMicroseconds > 16000 ||
          t.rasterDuration.inMicroseconds > 16000) {
        slow++;
      }
      if (t.totalSpan > worst) worst = t.totalSpan;
    }
    if (DateTime.now().difference(since) < const Duration(seconds: 5)) return;
    total.sort();
    debugPrint(
      'frames=$frames slow(build or raster >16ms)=$slow '
      'p50=${total[total.length ~/ 2]}ms p95=${total[(total.length * .95).floor()]}ms worst=${worst.inMilliseconds}ms',
    );
    frames = 0;
    slow = 0;
    worst = Duration.zero;
    total.clear();
    since = DateTime.now();
  });
}
