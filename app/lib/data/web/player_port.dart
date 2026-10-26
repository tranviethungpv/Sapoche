import '../models.dart';

/// Why [PlayerPort.prepare] could not load an item. Trying again at once does not help with either.
enum LoadReason {
  /// The device has no network.
  offline,

  /// YouTube will not play this video here: removed, private, blocked from embedding, age restricted, live.
  unplayable,
}

class LoadFailure implements Exception {
  LoadFailure(this.reason, this.message);

  final LoadReason reason;
  final String message;

  /// The [LoadFailure] behind [error], or null when it is some other error.
  static LoadFailure? of(Object? error) => error is LoadFailure ? error : null;

  @override
  String toString() => message;
}

/// What the session needs from a local player. Mirrors PlayerPort in GroupSession.kt.
abstract class PlayerPort {
  /// Load [item] paused at [seekToMs]. Completes once playback can start at once; throws if the item cannot be loaded,
  /// a [LoadFailure] when the player knows why.
  Future<void> prepare(QueueEntry item, int seekToMs);

  /// Forget where [videoId] streams from, so that the next [prepare] asks again.
  void refresh(String videoId);

  /// Seeks and completes once the player is ready at the new position, or once it gave up waiting.
  Future<void> seekTo(int positionMs);

  void play();
  void pause();
  void stop();
  void setSpeed(double speed);

  /// Queue [item] to play right after the current one, or drop the queued item when null. A player that cannot play
  /// without a gap may ignore it, but then must never call [onAdvanced].
  void setNext(QueueEntry? item);

  int positionMs();
  bool isPlaying();

  /// A song is loaded and waiting for data; only for the progress bar, so a player may leave it false.
  bool isBuffering() => false;

  /// Length of the loaded song, 0 until the player knows it.
  int durationMs() => 0;

  /// The loaded item played to its end and nothing was queued after it.
  void Function()? onEnded;

  /// The player moved on to the item given to [setNext] by itself.
  void Function()? onAdvanced;

  /// Playback failed after it started.
  void Function(Object error)? onError;
}
