import 'dart:collection';

/// Monotonic local clock in ms, the one clock the clock sync and the session both read.
typedef NowMs = int Function();

/// Estimates the offset between this device's monotonic clock and the server clock, NTP style. Mirrors ClockSync.kt:
/// the sample with the smallest error bound wins, a bound that grows with the sample's age.
class ClockSync {
  ClockSync({this.windowSize = 12});

  final int windowSize;
  final _samples = Queue<_Sample>();

  /// How fast two clocks may drift apart: 100 parts per million, with margin.
  static const _driftPerMs = 100e-6;

  void addSample(int c0, int c2, int s1) {
    final rtt = (c2 - c0).toDouble();
    if (rtt < 0) return;
    _samples.addLast(_Sample(s1 - (c0 + rtt / 2), rtt, c2));
    while (_samples.length > windowSize) {
      _samples.removeFirst();
    }
  }

  bool get hasSync => _samples.isNotEmpty;

  /// Server time minus local time. 0 until the first sample.
  double get offsetMs => _best()?.offsetMs ?? 0;

  /// Round trip of the sample the offset is based on, or null before the first sample.
  double? get bestRttMs => _best()?.rttMs;

  _Sample? _best() {
    if (_samples.isEmpty) return null;
    final newest = _samples.last.atMs;
    _Sample? best;
    var bound = double.infinity;
    for (final s in _samples) {
      final b = s.rttMs / 2 + (newest - s.atMs) * _driftPerMs;
      if (b < bound) {
        bound = b;
        best = s;
      }
    }
    return best;
  }

  int toServer(int localMs) => localMs + offsetMs.truncate();
  int toLocal(int serverMs) => serverMs - offsetMs.truncate();
}

class _Sample {
  const _Sample(this.offsetMs, this.rttMs, this.atMs);
  final double offsetMs;
  final double rttMs;
  final int atMs;
}

sealed class DriftAction {
  const DriftAction();
}

class DriftNone extends DriftAction {
  const DriftNone();
}

class DriftSetSpeed extends DriftAction {
  const DriftSetSpeed(this.factor);
  final double factor;
}

class DriftSeek extends DriftAction {
  const DriftSeek();
}

/// Decides how to pull a player back in line with the room. Mirrors DriftController.kt, except that a player that
/// cannot change speed in small steps (a YouTube frame only knows 0.25, 0.5, ... 2) passes [speedDelta] 0 and is only
/// ever moved by a seek.
class DriftController {
  DriftController({
    this.deadbandMs = 40,
    this.settleMs = 15,
    this.seekThresholdMs = 400,
    this.speedDelta = 0.03,
  });

  final int deadbandMs;
  final int settleMs;
  final int seekThresholdMs;
  final double speedDelta;

  /// -1 while slowing down, +1 while speeding up, 0 at normal speed.
  int _correcting = 0;

  DriftAction decide(int driftMs) {
    final size = driftMs.abs();
    if (size > seekThresholdMs) {
      // The caller restores normal speed together with the seek
      _correcting = 0;
      return const DriftSeek();
    }
    if (speedDelta == 0) return const DriftNone();

    if (_correcting == 0) {
      if (size <= deadbandMs) return const DriftNone();
      _correcting = driftMs > 0 ? -1 : 1;
      return DriftSetSpeed(1 + _correcting * speedDelta);
    }

    // Currently correcting: stop when close enough or when we overshot to the other side
    final overshot =
        (_correcting == -1 && driftMs <= 0) || (_correcting == 1 && driftMs >= 0);
    if (size <= settleMs || overshot) {
      _correcting = 0;
      return const DriftSetSpeed(1);
    }
    return const DriftNone();
  }

  void reset() => _correcting = 0;
}

/// Smooths the drift readings before they reach the [DriftController]. Mirrors DriftFilter in DriftController.kt.
class DriftFilter {
  DriftFilter({this.size = 8, this.minSamplesForLargeDrift = 3});

  final int size;
  final int minSamplesForLargeDrift;
  final _samples = Queue<double>();

  /// Total shift, in ms, that speed changes have applied to the position.
  double _correctionMs = 0;
  double _speed = 1;
  int _lastMs = 0;

  bool get isFull => _samples.length >= size;
  bool get hasLargeDriftEvidence => _samples.length >= minSamplesForLargeDrift;

  void _advance(int nowMs) {
    _correctionMs += (_speed - 1) * (nowMs - _lastMs);
    _lastMs = nowMs;
  }

  void add(int nowMs, int driftMs) {
    _advance(nowMs);
    _samples.addLast(driftMs - _correctionMs);
    if (_samples.length > size) _samples.removeFirst();
  }

  /// Mean drift the device would have without any correction, or null with no readings.
  double? uncorrectedMean() => _samples.isEmpty ? null : _mean();

  /// Best estimate of the drift at [nowMs], or null when there are no readings.
  int? estimate(int nowMs) {
    if (_samples.isEmpty) return null;
    _advance(nowMs);
    return (_mean() + _correctionMs).truncate();
  }

  void setSpeed(int nowMs, double newSpeed) {
    _advance(nowMs);
    _speed = newSpeed;
  }

  void reset(int nowMs, [double newSpeed = 1]) {
    _samples.clear();
    _correctionMs = 0;
    _speed = newSpeed;
    _lastMs = nowMs;
  }

  double _mean() => _samples.fold<double>(0, (a, b) => a + b) / _samples.length;
}
