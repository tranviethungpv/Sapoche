import 'dart:async';

import '../models.dart';

/// Stops the music after a while so that the person can fall asleep to it. The volume goes down over the last
/// [fadeMs] so that it does not end with a jolt. Dart counterpart of `SleepTimer.kt`.
///
/// [stop] pauses this device; [fade] sets the volume (1 is full) and [pauseAtSongEnd] asks the player to pause when the
/// song is over. The host calls [songEnded] once that happened.
///
/// What is left is read off the wall clock at every step, not counted in steps: a browser slows the timers of a tab it
/// cannot see, and the music must still stop on time.
class SleepTimer {
  SleepTimer({
    required this._wallClock,
    required this._stop,
    required this._fade,
    required this._pauseAtSongEnd,
    this.onChanged,
  });

  final int Function() _wallClock;
  final void Function() _stop;
  final void Function(double level) _fade;
  final void Function(bool on) _pauseAtSongEnd;

  /// Called after the timer was set, ran out or was turned off.
  final void Function(SleepState state)? onChanged;

  SleepState _state = const SleepState();
  Timer? _timer;

  SleepState get state => _state;

  static const fadeMs = 15000;
  static const fadeStepMs = 500;
  static const maxMinutes = 12 * 60;

  /// Stops in [minutes], replacing what was set before.
  void startIn(int minutes) {
    final ms = minutes.clamp(1, maxMinutes) * 60000;
    _reset();
    final end = _wallClock() + ms;
    _set(SleepState(mode: SleepMode.time, endsAt: DateTime.fromMillisecondsSinceEpoch(end)));
    _timer = Timer(Duration(milliseconds: ms > fadeMs ? ms - fadeMs : 0), () => _step(end));
  }

  void _step(int end) {
    final left = end - _wallClock();
    if (left <= 0) {
      _fire();
      return;
    }
    if (left <= fadeMs) _fade(left / fadeMs);
    _timer = Timer(Duration(milliseconds: left < fadeStepMs ? left : fadeStepMs), () => _step(end));
  }

  /// Stops at the end of the song playing now.
  void startAtSongEnd() {
    _reset();
    _set(const SleepState(mode: SleepMode.song));
    _pauseAtSongEnd(true);
  }

  void cancel() {
    _reset();
    _set(const SleepState());
  }

  /// The player paused at the end of a song, or the queue ran out.
  void songEnded() {
    if (_state.mode == SleepMode.song) _fire();
  }

  void _fire() {
    // Silence first: the volume only comes back once the player is paused
    _stop();
    _reset();
    _set(const SleepState());
  }

  /// Undoes what the timer did to the player.
  void _reset() {
    _timer?.cancel();
    _timer = null;
    _fade(1);
    _pauseAtSongEnd(false);
  }

  void _set(SleepState state) {
    _state = state;
    onChanged?.call(state);
  }
}
