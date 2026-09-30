import 'dart:math';

import 'models.dart';
import 'music_models.dart';
import 'song_key.dart';

/// The songs of one artist the person listens to, as a mix to start: it begins with [seed], the song of that
/// artist heard most.
class ArtistMix {
  const ArtistMix({required this.artist, required this.seed});

  final String artist;
  final Track seed;
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
    this.forgotten = const [],
    this.becauseOf = const [],
    this.topSeed,
  });

  /// Songs to try, from the suggestions kept for the person's favourite songs.
  final List<Track> quickPicks;

  /// Songs heard lately, the latest first.
  final List<Track> listenAgain;
  final List<ArtistMix> mixes;

  /// Liked songs that have not been heard for a long while.
  final List<Track> forgotten;
  final List<BecauseOf> becauseOf;

  /// The song the person plays most, which the rows that need a song to start from use.
  final Track? topSeed;

  /// Nothing known about the person yet: only what is the same for everybody can be shown.
  bool get isEmpty =>
      quickPicks.isEmpty &&
      listenAgain.isEmpty &&
      mixes.isEmpty &&
      forgotten.isEmpty &&
      becauseOf.isEmpty;
}

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
}) {
  // How much each song, and each artist, is loved
  final scores = <Track, double>{};
  for (final e in recent) {
    scores[e.track] = e.plays * _recency(e.at, now);
  }
  for (final t in liked) {
    scores[t] = (scores[t] ?? 0) + _likeWeight;
  }
  final ranked = scores.keys.toList()
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
    if (seed == null) continue;
    final tracks = uniqueSongs(list.tracks.where((t) => !isKnown(t)))
        .take(15)
        .toList();
    if (tracks.length >= 3) because.add(BecauseOf(seed: seed, tracks: tracks));
    if (because.length == 2) break;
  }

  return HomeShelves(
    quickPicks: uniqueSongs(forYou).take(20).toList(),
    listenAgain: [for (final e in recent.take(12)) e.track],
    mixes: mixes,
    forgotten: uniqueSongs(liked.where(forgottenSong)).take(12).toList(),
    becauseOf: because,
    topSeed: ranked.isEmpty ? null : ranked.first,
  );
}
