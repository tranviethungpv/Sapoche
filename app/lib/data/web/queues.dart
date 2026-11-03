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

  /// The most songs autoplay asks for radios of in all, its own and the members' offers together.
  static const maxBlend = 5;

  /// [base] (see [seeds]) with one song of each member's offer, to look for songs that suit the room and not only the
  /// last song: [offers] are the video ids each member offered, in the order they gave them. Which song of an offer, and
  /// which members when there are not places for all, goes round with [epoch], so the next time the room runs out it is
  /// others'. Songs already among the seeds are not taken twice. At most [max] come back in all.
  static List<String> blend(List<String> base, List<List<String>> offers, int epoch, {int max = maxBlend}) {
    final result = [...base];
    final members = offers.where((o) => o.isNotEmpty).toList();
    if (members.isEmpty) return result;
    final start = epoch % members.length;
    for (var i = 0; i < members.length; i++) {
      if (result.length >= max) break;
      final offer = members[(start + i) % members.length];
      final pick = [for (var k = 0; k < offer.length; k++) offer[(epoch + k) % offer.length]].where((id) => !result.contains(id)).firstOrNull;
      if (pick != null) result.add(pick);
    }
    return result;
  }
}
