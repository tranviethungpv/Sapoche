import '../models.dart';

/// What a room's queue says about what to play next. Dart counterpart of `Queues.kt` (the part that fresh songs are
/// picked by lives in `RoomSnapshot.fresh`).
abstract final class Queues {
  /// The most songs autoplay asks a radio for at once: more would be many requests for a room that has run dry.
  static const maxSeeds = 3;

  /// The songs a room's autoplay looks for more of: [ask], the last song, then the songs of [queue] that members put
  /// there, the latest first, one for each member who has not a song among them yet. Songs autoplay itself put there are
  /// not a member's choice and are left out. A room where one member added everything gives [ask] alone, as it always did.
  static List<String> seeds(List<QueueEntry> queue, String ask, {int max = maxSeeds}) {
    final seeds = [ask];
    final adders = <String>{};
    final asked = queue.where((e) => e.videoId == ask && !e.auto).lastOrNull;
    if (asked != null) adders.add(asked.addedBy);
    for (final item in queue.reversed) {
      if (seeds.length >= max) break;
      if (item.auto || seeds.contains(item.videoId) || !adders.add(item.addedBy)) continue;
      seeds.add(item.videoId);
    }
    return seeds;
  }
}
