import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Whether the build prints frame statistics: profile builds always, other builds when made with
/// `--dart-define=FRAME_STATS=true` (a release build that can be measured and installed over the real one).
const _wanted = bool.fromEnvironment('FRAME_STATS');

/// Prints, every few seconds while frames are being drawn, how many missed the time the display gives them
/// (build or raster longer than one refresh) and how far apart the frames really were, which tells the refresh
/// rate the app got: 8 ms between frames is 120 Hz, 16 ms is 60. Read it with `adb logcat -s flutter`.
void watchFrames() {
  if (!kProfileMode && !_wanted) return;
  var frames = 0, slow = 0;
  var worst = Duration.zero;
  final total = <int>[];
  final builds = <int>[];
  final rasters = <int>[];
  final gaps = <int>[];
  int? lastVsync;
  var since = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    final rate =
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.display
            .refreshRate ??
        60;
    // What one refresh allows, in microseconds: a frame that takes longer than that is seen as a stutter
    final budget = (1e6 / rate).round();
    for (final t in timings) {
      frames++;
      total.add(t.totalSpan.inMilliseconds);
      builds.add(t.buildDuration.inMicroseconds);
      rasters.add(t.rasterDuration.inMicroseconds);
      if (t.buildDuration.inMicroseconds > budget ||
          t.rasterDuration.inMicroseconds > budget) {
        slow++;
      }
      if (t.totalSpan > worst) worst = t.totalSpan;
      final vsync = t.timestampInMicroseconds(FramePhase.vsyncStart);
      // Only gaps between frames that came one after another say anything about the rate
      final before = lastVsync;
      if (before != null && vsync - before < 40000) {
        gaps.add(vsync - before);
      }
      lastVsync = vsync;
    }
    if (DateTime.now().difference(since) < const Duration(seconds: 5)) return;
    total.sort();
    gaps.sort();
    builds.sort();
    rasters.sort();
    String ms(List<int> micros, double q) =>
        (micros[((micros.length - 1) * q).floor()] / 1000).toStringAsFixed(1);
    final gap = gaps.isEmpty
        ? 'n/a'
        : '${(gaps[gaps.length ~/ 2] / 1000).toStringAsFixed(1)}ms';
    debugPrint(
      'frames=$frames slow(build or raster over one refresh of ${(budget / 1000).toStringAsFixed(1)}ms)=$slow '
      'p50=${total[total.length ~/ 2]}ms p95=${total[(total.length * .95).floor()]}ms worst=${worst.inMilliseconds}ms '
      'build p50/p95=${ms(builds, .5)}/${ms(builds, .95)}ms raster p50/p95=${ms(rasters, .5)}/${ms(rasters, .95)}ms '
      'gap between frames p50=$gap display=${rate.round()}Hz',
    );
    frames = 0;
    slow = 0;
    worst = Duration.zero;
    total.clear();
    gaps.clear();
    builds.clear();
    rasters.clear();
    since = DateTime.now();
  });
}
