/// What a device that fell behind the room does about it while its network is weak, see [NetworkHealth.catchUp].
sealed class CatchUp {
  const CatchUp();
}

/// Keep playing at normal speed: the data to go faster is not there.
class CatchUpWait extends CatchUp {
  const CatchUpWait();
}

/// Close the gap by speeding up a little: it is small and the buffer can pay for it.
class CatchUpSpeed extends CatchUp {
  const CatchUpSpeed(this.factor);

  final double factor;
}

/// One seek to where the room is: the buffer holds that place.
class CatchUpSeekInBuffer extends CatchUp {
  const CatchUpSeekInBuffer();
}

/// Too far behind to wait for: pause, load the room's place, and start there at an agreed moment.
class CatchUpJump extends CatchUp {
  const CatchUpJump();
}

/// Tells a network that is slow or comes and goes from a good one, from the stalls a player reports, and keeps what the
/// session learned about it. Pure logic on the caller's monotonic clock; one per session. Mirrors NetworkHealth.kt.
///
/// A good network never gets here: the first stall that is not the player's own doing turns [weak] on, and a minute
/// without another one, with a full buffer ahead, turns it off.
class NetworkHealth {
  bool weak = false;

  /// How long loading a place the player does not have takes, learned from jumps and loads. Aims the next start.
  int loadMs = defaultLoadMs;

  int _lastStallEndMs = 0;

  /// The player stalled, and played again at [nowMs]. Returns true when this is what turned weak mode on.
  bool onStall(int nowMs) {
    _lastStallEndMs = nowMs;
    final turned = !weak;
    weak = true;
    return turned;
  }

  /// A jump to a place the player had to load took [tookMs] against the lead it was given.
  void learnLoad(int tookMs) {
    loadMs = ((loadMs + tookMs * _loadMargin) / 2).toInt().clamp(minLoadMs, maxLoadMs);
  }

  /// A jump did not make its moment at [nowMs]: ask for more time next, and count it as a stall for how long the network stays weak.
  void onJumpMissed(int nowMs, int tookMs) {
    _lastStallEndMs = nowMs;
    weak = true;
    loadMs = ((loadMs > tookMs ? loadMs : tookMs) * 2).clamp(minLoadMs, maxLoadMs);
  }

  /// Whether [nowMs] is late enough in a calm spell, with [aheadMs] of song buffered, to go back to the plain rules.
  bool tick(int nowMs, int aheadMs, {required bool fullyLoaded}) {
    if (!weak) return false;
    if (nowMs - _lastStallEndMs < quietMs) return false;
    if (aheadMs < recoveredAheadMs && !fullyLoaded) return false;
    weak = false;
    loadMs = defaultLoadMs;
    return true;
  }

  /// How a device [lagMs] behind the room (positive) catches up while the network is weak, with [aheadMs] of the song
  /// already loaded ahead of its position.
  CatchUp catchUp(int lagMs, int aheadMs) {
    if (lagMs > maxLagMs) return const CatchUpJump();
    if (lagMs < speedLagMs && aheadMs >= speedAheadMs) return const CatchUpSpeed(1.03);
    if (aheadMs >= lagMs + seekBufferMs) return const CatchUpSeekInBuffer();
    return const CatchUpWait();
  }

  static const defaultLoadMs = 3000;
  static const minLoadMs = 2000;
  static const maxLoadMs = 10000;
  static const _loadMargin = 1.5;

  /// No stall for this long, and a buffer of [recoveredAheadMs], and the network counts as good again.
  static const quietMs = 60000;
  static const recoveredAheadMs = 30000;

  /// A device may run this far behind the room before it jumps, rather than stall again to close the gap.
  static const maxLagMs = 15000;
  static const seekBufferMs = 10000;
  static const speedLagMs = 1500;
  static const speedAheadMs = 20000;

  /// At most one seek this often while weak; a seek that is followed by a stall doubles it.
  static const seekGapMs = 20000;
}
