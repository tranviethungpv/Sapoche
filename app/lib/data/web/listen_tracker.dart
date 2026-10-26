/// Decides when a song counts as heard: after [heardMs] of playing it, or half of it when it is shorter than a minute.
/// Only time spent playing counts, so pauses and buffering do not, and seeking neither adds nor skips anything.
///
/// A song that is left before it counts, after a few seconds, is reported as skipped.
///
/// It keeps no clock and no timer: the caller passes the time in. Dart counterpart of `ListenTracker.kt`.
class ListenTracker {
  ListenTracker({this.skipped, required this.heard});

  /// Called once for a song left after a few seconds, before it counted, with its id and length: the person did not
  /// want it.
  final void Function(String id, int durationMs)? skipped;

  /// Called once per song, with its id and the length last reported (0 if unknown).
  final void Function(String id, int durationMs) heard;

  String? _id;
  int _durationMs = 0;
  int _playedMs = 0;
  int? _playingSince;
  bool _counted = false;

  static const heardMs = 30000;

  /// A song left after at least this long, and before it counted, was skipped; less is a change of mind or a glitch.
  static const skippedMs = 3000;

  /// A different song is now loaded, or with a null [songId] nothing is.
  void begin(String? songId, int durationMs, int now) {
    check(now);
    final leaving = _id;
    final since = _playingSince;
    if (leaving != null && !_counted && _playedMs + (since == null ? 0 : now - since) >= skippedMs) {
      skipped?.call(leaving, _durationMs);
    }
    _id = songId;
    _durationMs = durationMs < 0 ? 0 : durationMs;
    _playedMs = 0;
    _playingSince = null;
    _counted = false;
  }

  /// The song's length became known.
  void setDuration(int ms) {
    if (ms > 0) _durationMs = ms;
  }

  void setPlaying(bool playing, int now) {
    if (_id == null) return;
    check(now);
    final since = _playingSince;
    if (playing && since == null) {
      _playingSince = now;
    } else if (!playing && since != null) {
      _playedMs += now - since;
      _playingSince = null;
    }
  }

  /// How long until the song counts if it keeps playing, or null when that is not going to happen.
  int? msUntilHeard(int now) {
    final since = _playingSince;
    if (since == null || _id == null || _counted) return null;
    final left = _threshold() - _playedMs - (now - since);
    return left < 0 ? 0 : left;
  }

  /// Counts the song if it has been played long enough by [now].
  void check(int now) {
    final current = _id;
    if (current == null || _counted) return;
    final since = _playingSince;
    if (_playedMs + (since == null ? 0 : now - since) < _threshold()) return;
    _counted = true;
    heard(current, _durationMs);
  }

  int _threshold() => _durationMs > 0 && _durationMs ~/ 2 < heardMs ? _durationMs ~/ 2 : heardMs;
}
