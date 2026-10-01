import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Tells the display when the screen is really moving, so that it runs at its fastest only then. Frames that
/// follow one another closely (a drag, a fling, a page sliding in) are movement; the few frames a second of a
/// seek bar or the bars of the equalizer are not, and must not hold a 120 Hz display awake.
class FrameBoost {
  FrameBoost(this._set, {Duration? idle})
    : _idle = idle ?? const Duration(milliseconds: 700);

  final void Function(bool on) _set;
  final Duration _idle;

  /// Frames closer than this are one movement.
  static const _together = Duration(milliseconds: 40);

  /// How many in a row make it movement.
  static const _streakToBoost = 4;

  Duration? _last;
  int _streak = 0;
  bool _boosted = false;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;

  bool get boosted => _boosted;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  void _onFrame(Duration time) {
    if (_disposed) return;
    final last = _last;
    _last = time;
    _streak = last != null && time - last < _together ? _streak + 1 : 1;
    if (!_boosted && _streak >= _streakToBoost) {
      _boosted = true;
      _set(true);
    }
    if (_boosted) {
      _timer?.cancel();
      _timer = Timer(_idle, _release);
    }
  }

  void _release() {
    _boosted = false;
    _streak = 0;
    _set(false);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_boosted) _set(false);
  }
}
