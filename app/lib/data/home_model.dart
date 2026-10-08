import 'dart:math';

import 'models.dart';
import 'music_models.dart';
import 'song_key.dart';
import 'taste_clusters.dart';

/// The songs of one artist the person listens to, as a mix to start: it begins with [seed], the song of that
/// artist heard most.
class ArtistMix {
  const ArtistMix({required this.artist, required this.seed});

  final String artist;
  final Track seed;
}

/// A mix of one taste of the person's: songs of the artists they play together, some they know and some they do not.
/// It is made again every day from the same material, so the same morning does not bring the same list.
class DailyMix {
  const DailyMix({
    required this.number,
    required this.artists,
    required this.tracks,
  });

  /// Which mix it is, from 1: the one for the taste the person plays most.
  final int number;

  /// The artists it is made of, as they are written, the best loved first.
  final List<String> artists;
  final List<Track> tracks;

  /// Up to four different pictures to show together as its cover.
  List<String> get covers {
    final seen = <String>{};
    return [
      for (final t in tracks)
        if (t.thumb != null && seen.add(t.thumb!)) t.thumb!,
    ].take(4).toList();
  }
}

/// A row of songs that YouTube Music lists beside a song the person listened to.
class BecauseOf {
  const BecauseOf({required this.seed, required this.tracks});

  final Track seed;
  final List<Track> tracks;
}

/// What the home page shows, worked out from what the person listened to. Every list is ready to draw: nothing
/// here needs the network.
class HomeShelves {
  const HomeShelves({
    this.quickPicks = const [],
    this.listenAgain = const [],
    this.mixes = const [],
    this.dailyMixes = const [],
    this.forgotten = const [],
    this.becauseOf = const [],
    this.discover = const [],
    this.context = const [],
    this.contextBucket = '',
    this.topSeed,
  });

  /// Songs to try, from the suggestions kept for the person's favourite songs.
  final List<Track> quickPicks;

  /// Songs heard lately, the latest first.
  final List<Track> listenAgain;
  final List<ArtistMix> mixes;
  final List<DailyMix> dailyMixes;

  /// Liked songs that have not been heard for a long while.
  final List<Track> forgotten;
  final List<BecauseOf> becauseOf;

  /// Songs by artists the person does not know yet.
  final List<Track> discover;

  /// What the person plays at this time of day and songs like it, with the part of the day it is for.
  final List<Track> context;
  final String contextBucket;

  /// The song the person plays most, which the rows that need a song to start from use.
  final Track? topSeed;

  /// Nothing known about the person yet: only what is the same for everybody can be shown.
  bool get isEmpty =>
      quickPicks.isEmpty &&
      listenAgain.isEmpty &&
      mixes.isEmpty &&
      dailyMixes.isEmpty &&
      forgotten.isEmpty &&
      becauseOf.isEmpty &&
      discover.isEmpty &&
      context.isEmpty;
}

/// The part of the day an hour is in, as the native side tells them apart: `morning`, `afternoon`, `evening` or `night`.
String dayPartOf(DateTime time) => switch (time.hour) {
  >= 5 && <= 10 => 'morning',
  >= 11 && <= 16 => 'afternoon',
  >= 17 && <= 21 => 'evening',
  _ => 'night',
};

/// A play counts for less as it gets older: half as much after a month.
const _halfLife = Duration(days: 30);

/// A liked song counts for as much as two plays.
const _likeWeight = 2.0;

const _forgottenAfter = Duration(days: 30);

double _recency(DateTime at, DateTime now) =>
    pow(0.5, now.difference(at).inHours / _halfLife.inHours).toDouble();

/// Picks the rows of the home page from the person's history, likes and the suggestions kept for them.
HomeShelves buildHome({
  required List<HistoryEntry> recent,
  required List<Track> liked,
  required List<Track> forYou,
  required List<SeedList> seedLists,
  required DateTime now,
  List<Track> discover = const [],
  ContextMix context = const ContextMix(),
  List<BlockedItem> blocked = const [],

  /// Every listen with its own time (see [clusterTaste]); without them there are no mixes of a taste.
  List<HistoryEntry> listens = const [],
}) {
  // What the person asked not to be offered shows nowhere, whatever was kept before they asked
  final blockedSongs = {
    for (final b in blocked)
      if (!b.isArtist) b.key,
  };
  final blockedArtists = {
    for (final b in blocked)
      if (b.isArtist) b.key,
  };
  bool allowed(Track t) =>
      !blockedSongs.contains(t.videoId) &&
      !blockedArtists.contains(mainArtist(t.artist));

  // How much each song, and each artist, is loved
  final scores = <Track, double>{};
  for (final e in recent) {
    scores[e.track] = e.plays * _recency(e.at, now);
  }
  for (final t in liked) {
    scores[t] = (scores[t] ?? 0) + _likeWeight;
  }
  final ranked = scores.keys.where(allowed).toList()
    ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

  final byArtist = <String, List<Track>>{};
  final artistScore = <String, double>{};
  for (final t in ranked) {
    final artist = mainArtist(t.artist);
    if (artist.isEmpty) continue;
    byArtist.putIfAbsent(artist, () => []).add(t);
    artistScore[artist] = (artistScore[artist] ?? 0) + scores[t]!;
  }
  final topArtists = byArtist.keys.toList()
    ..sort((a, b) => artistScore[b]!.compareTo(artistScore[a]!));
  final mixes = topArtists.length < 2
      ? <ArtistMix>[]
      : [
          for (final artist in topArtists.take(6))
            ArtistMix(
              artist: displayArtist(byArtist[artist]!.first.artist),
              seed: byArtist[artist]!.first,
            ),
        ];

  // Liked songs the person has not been near for a month
  final heardByKey = <String, List<HistoryEntry>>{};
  for (final e in recent) {
    heardByKey
        .putIfAbsent(songKey(e.track.title, e.track.artist), () => [])
        .add(e);
  }
  bool forgottenSong(Track t) {
    final heard = [
      for (final e
          in heardByKey[songKey(t.title, t.artist)] ?? const <HistoryEntry>[])
        if (sameSong(e.track, t)) e.at,
    ];
    return heard.isEmpty ||
        now.difference(heard.reduce((a, b) => a.isAfter(b) ? a : b)) >
            _forgottenAfter;
  }

  // "Because you listened to": the suggestions of the songs the person knows, leaving out what they know
  final known = [...recent.map((e) => e.track), ...liked];
  final knownByKey = <String, List<Track>>{};
  for (final t in known) {
    knownByKey.putIfAbsent(songKey(t.title, t.artist), () => []).add(t);
  }
  bool isKnown(Track t) =>
      knownByKey[songKey(t.title, t.artist)]?.any((k) => sameSong(k, t)) ??
      false;
  Track? titled(String videoId) {
    for (final t in known) {
      if (t.videoId == videoId) return t;
    }
    return null;
  }

  final because = <BecauseOf>[];
  for (final list in seedLists) {
    final seed = titled(list.seed);
    if (seed == null || !allowed(seed)) continue;
    final tracks = uniqueSongs(
      list.tracks.where((t) => allowed(t) && !isKnown(t)),
    ).take(15).toList();
    if (tracks.length >= 3) because.add(BecauseOf(seed: seed, tracks: tracks));
    if (because.length == 2) break;
  }

  final lastHeard = {for (final e in recent) e.track.videoId: e.at};
  final picks = seedLists.isEmpty
      ? uniqueSongs(forYou.where(allowed)).take(20).toList()
      : _rankPicks(
          seedLists: seedLists,
          forYou: forYou,
          scores: scores,
          artistScore: artistScore,
          allowed: allowed,
          excluded: (t) =>
              liked.any((l) => l.videoId == t.videoId) ||
              (lastHeard[t.videoId]?.isAfter(
                    now.subtract(const Duration(days: 7)),
                  ) ??
                  false),
        );

  return HomeShelves(
    quickPicks: picks,
    listenAgain: [for (final e in recent.take(12)) e.track],
    mixes: mixes,
    dailyMixes: _dailyMixes(
      clusters: clusterTaste(listens: listens, weights: artistScore),
      ranked: ranked,
      lastHeard: lastHeard,
      seedLists: seedLists,
      titled: titled,
      isKnown: isKnown,
      allowed: allowed,
      now: now,
    ),
    forgotten: uniqueSongs(liked.where((t) => allowed(t) && forgottenSong(t)))
        .take(12)
        .toList(),
    becauseOf: because,
    discover: uniqueSongs(discover.where(allowed)).take(20).toList(),
    context: uniqueSongs(context.tracks.where(allowed)).take(20).toList(),
    contextBucket: context.bucket,
    topSeed: ranked.isEmpty ? null : ranked.first,
  );
}

/// The songs YouTube Music lists beside the songs the person loves, best first.
///
/// A song listed beside several of the songs they love is likelier to suit them than one listed beside a single
/// song, so every list votes for the songs in it: the more the seed is loved and the nearer the top the song stands,
/// the more the vote counts. An artist the person plays adds to the score. Then the list is made to be varied: no
/// artist comes more than twice, and three places in ten are kept for artists the person does not play yet, so
/// that what they like is not all they are offered.
List<Track> _rankPicks({
  required List<SeedList> seedLists,
  required List<Track> forYou,
  required Map<Track, double> scores,
  required Map<String, double> artistScore,
  required bool Function(Track) allowed,
  required bool Function(Track) excluded,
  int limit = 24,
}) {
  final scoreOf = {for (final e in scores.entries) e.key.videoId: e.value};
  final seedScores = [for (final list in seedLists) scoreOf[list.seed] ?? 0.0];
  final strongest = seedScores.fold(0.0, (m, v) => v > m ? v : m);
  final votes = <String, double>{};
  final lists = <String, int>{};
  final byId = <String, Track>{};
  void vote(Track t, double weight) {
    byId.putIfAbsent(t.videoId, () => t);
    votes[t.videoId] = (votes[t.videoId] ?? 0) + weight;
  }

  for (final (i, list) in seedLists.indexed) {
    // A seed that is loved less counts for less, but never for nothing
    final weight = strongest <= 0
        ? 1.0
        : (0.3 + 0.7 * seedScores[i] / strongest);
    for (final (position, t) in list.tracks.indexed) {
      if (!allowed(t) || excluded(t) || t.videoId == list.seed) continue;
      vote(t, weight / (1 + position / 8));
      lists[t.videoId] = (lists[t.videoId] ?? 0) + 1;
    }
  }
  // What the native side composed already is a vote too, a small one
  for (final t in forYou) {
    if (allowed(t) && !excluded(t)) vote(t, 0.1);
  }

  final topArtist = artistScore.values.fold(0.0, (m, v) => v > m ? v : m);
  double affinity(Track t) =>
      topArtist <= 0 ? 0 : (artistScore[mainArtist(t.artist)] ?? 0) / topArtist;
  double score(Track t) =>
      votes[t.videoId]! +
      0.35 * affinity(t) +
      // Beside two or more loved songs, by somebody new: the likeliest discovery
      (affinity(t) <= 0 && (lists[t.videoId] ?? 0) >= 2 ? 0.1 : 0);

  final ordered = uniqueSongs(
    byId.values.toList()..sort((a, b) => score(b).compareTo(score(a))),
  );
  final chosen = <Track>[];
  final perArtist = <String, int>{};
  final taken = <String>{};
  bool fits(Track t) =>
      !taken.contains(t.videoId) && (perArtist[mainArtist(t.artist)] ?? 0) < 2;
  void take(Track t) {
    taken.add(t.videoId);
    perArtist.update(mainArtist(t.artist), (n) => n + 1, ifAbsent: () => 1);
    chosen.add(t);
  }

  while (chosen.length < limit) {
    // Places 3, 6 and 9 of every ten are for artists not played yet
    final wantNew = const {2, 5, 8}.contains(chosen.length % 10);
    Track? next;
    if (wantNew) {
      next = ordered.where((t) => fits(t) && affinity(t) <= 0.05).firstOrNull;
    }
    next ??= ordered.where(fits).firstOrNull;
    if (next == null) break;
    take(next);
  }
  return chosen;
}

/// A mix for every taste of the person's (see [clusterTaste]): two songs they know for every one they do not, in an
/// order that changes each day.
List<DailyMix> _dailyMixes({
  required List<TasteCluster> clusters,
  required List<Track> ranked,
  required Map<String, DateTime> lastHeard,
  required List<SeedList> seedLists,
  required Track? Function(String) titled,
  required bool Function(Track) isKnown,
  required bool Function(Track) allowed,
  required DateTime now,
}) {
  final day = now.year * 10000 + now.month * 100 + now.day;
  final everyTaste = {for (final c in clusters) ...c.artists};
  final mixes = <DailyMix>[];
  for (final (i, cluster) in clusters.indexed) {
    final members = cluster.artists.toSet();
    bool inTaste(Track t) => members.contains(mainArtist(t.artist));

    // What they know: the songs of the group they love most, leaving out the last two days
    // Counted in whole days, so that the mix does not change as the day goes on
    final recentCut = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 2));
    var known = ranked.where(inTaste).toList();
    final rested = known
        .where((t) => !(lastHeard[t.videoId]?.isAfter(recentCut) ?? false))
        .toList();
    if (rested.length >= 6) known = rested;

    // What they do not: beside the songs of this group in the lists YouTube Music kept, or by its artists; not by
    // an artist of another group, whose songs belong to another mix
    final fresh = <Track>[];
    for (final list in seedLists) {
      final seed = titled(list.seed);
      final fromTaste = seed != null && inTaste(seed);
      for (final t in list.tracks) {
        final artist = mainArtist(t.artist);
        final elsewhere =
            everyTaste.contains(artist) && !members.contains(artist);
        if (allowed(t) &&
            !isKnown(t) &&
            !elsewhere &&
            (fromTaste || inTaste(t))) {
          fresh.add(t);
        }
      }
    }

    final random = Random(day * 31 + i);
    final familiar = _dailyPick(known.take(24), random, 16);
    final unknown = _dailyPick(uniqueSongs(fresh).take(16), random, 8);
    final tracks = <Track>[];
    final perArtist = <String, int>{};
    void add(Track? t) {
      if (t == null) return;
      final artist = mainArtist(t.artist);
      if ((perArtist[artist] ?? 0) >= 4 ||
          tracks.any((k) => k.videoId == t.videoId)) {
        return;
      }
      perArtist[artist] = (perArtist[artist] ?? 0) + 1;
      tracks.add(t);
    }

    // Two they know, then one they do not
    var knownAt = 0;
    var unknownAt = 0;
    while (knownAt < familiar.length || unknownAt < unknown.length) {
      for (var k = 0; k < 2 && knownAt < familiar.length; k++) {
        add(familiar[knownAt++]);
      }
      if (unknownAt < unknown.length) add(unknown[unknownAt++]);
    }
    if (tracks.length < 6) continue;
    mixes.add(
      DailyMix(
        number: mixes.length + 1,
        artists: [
          for (final key in cluster.artists)
            displayArtist(
              ranked.firstWhere((t) => mainArtist(t.artist) == key).artist,
            ),
        ],
        tracks: tracks,
      ),
    );
  }
  return mixes;
}

/// [count] of the songs of [pool], mixed in an order that is the same all day: the pool is put in a fixed order first,
/// so that the order it came in does not matter.
List<Track> _dailyPick(Iterable<Track> pool, Random random, int count) =>
    (pool.toList()
          ..sort((a, b) => a.videoId.compareTo(b.videoId))
          ..shuffle(random))
        .take(count)
        .toList();
