import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/calm.dart';

/// Calls [onTick] every [period] (twice as slowly while the phone is warm, see [Calm]) while it is switched on
/// and the app is on screen. For small
/// moving parts that look the same at a few frames a second: a ticker would wake the phone on
/// every screen refresh, 60 to 120 times a second, for a change nobody can see.
class LowRateTimer with WidgetsBindingObserver {
  LowRateTimer(this.period, this.onTick) {
    WidgetsBinding.instance.addObserver(this);
    Calm.on.addListener(_pace);
    final state = WidgetsBinding.instance.lifecycleState;
    _onScreen = state == null || _isOnScreen(state);
  }

  final Duration period;
  final VoidCallback onTick;

  Timer? _timer;
  bool _wanted = false;
  bool _onScreen = true;

  bool get isRunning => _timer != null;

  static bool _isOnScreen(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  /// Switch the ticking on or off.
  void run(bool on) {
    _wanted = on;
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onScreen = _isOnScreen(state);
    _update();
  }

  /// The pace changed: a running timer starts again at the new one.
  void _pace() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _update();
  }

  void _update() {
    if (_wanted && _onScreen) {
      _timer ??= Timer.periodic(period * Calm.slowdown, (_) => onTick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Calm.on.removeListener(_pace);
    _timer?.cancel();
    _timer = null;
  }
}
