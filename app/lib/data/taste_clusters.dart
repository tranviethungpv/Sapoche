import 'dart:math';

import 'models.dart';
import 'song_key.dart';

/// A group of artists the person plays together: the kinds of music they come back to.
class TasteCluster {
  const TasteCluster({required this.artists, required this.weight});

  /// The artists in plain letters (see [mainArtist]), the best loved first.
  final List<String> artists;

  /// How much the person plays this group: the sum of what they play of each artist.
  final double weight;
}

/// Listens further apart than this belong to different sessions.
const _sessionGap = Duration(minutes: 45);

/// Artists whose sessions overlap less than this are kept apart.
const _joinAbove = 0.3;

/// The artists the person plays, grouped by what they play together.
///
/// A session is a stretch of listening with no pause longer than [_sessionGap]. Two artists are alike when they turn
/// up in the same sessions (the cosine of the sessions they are in), and groups are joined, most alike first, for as
/// long as the average likeness of their artists stays above [_joinAbove]. Nothing is learned from the sound or from
/// other people: the person's own habit is what tells a morning playlist from a night one. Artists that are never
/// played with another stay on their own.
///
/// [weights] says how much each of the artists is loved (see [mainArtist] for the keys); only the heaviest
/// [maxArtists] are grouped, and the heaviest [maxClusters] groups are given back, the heaviest first.
List<TasteCluster> clusterTaste({
  required List<HistoryEntry> listens,
  required Map<String, double> weights,
  int maxArtists = 24,
  int maxClusters = 4,
}) {
  final top =
      (weights.entries.where((e) => e.value > 0).toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(maxArtists)
          .map((e) => e.key)
          .toList();
  if (top.isEmpty) return const [];
  final wanted = top.toSet();

  // The artists of each session
  final ordered = [...listens]..sort((a, b) => a.at.compareTo(b.at));
  final sessions = <Set<String>>[];
  DateTime? last;
  for (final e in ordered) {
    final artist = mainArtist(e.track.artist);
    if (last == null || e.at.difference(last) > _sessionGap) {
      sessions.add({});
    }
    last = e.at;
    if (wanted.contains(artist)) sessions.last.add(artist);
  }
  final inSessions = {for (final a in top) a: 0};
  final together = <String, int>{};
  for (final session in sessions) {
    final members = session.toList()..sort();
    for (final a in members) {
      inSessions[a] = inSessions[a]! + 1;
    }
    for (var i = 0; i < members.length; i++) {
      for (var j = i + 1; j < members.length; j++) {
        final key = '${members[i]}\u0000${members[j]}';
        together[key] = (together[key] ?? 0) + 1;
      }
    }
  }
  double alike(String a, String b) {
    final key = a.compareTo(b) < 0 ? '$a\u0000$b' : '$b\u0000$a';
    final both = together[key] ?? 0;
    final na = inSessions[a]!;
    final nb = inSessions[b]!;
    return na == 0 || nb == 0 ? 0 : both / sqrt(na * nb);
  }

  // Join the most alike groups until none is alike enough
  var groups = [
    for (final a in top) [a],
  ];
  while (groups.length > 1) {
    var best = _joinAbove;
    int? from;
    int? into;
    for (var i = 0; i < groups.length; i++) {
      for (var j = i + 1; j < groups.length; j++) {
        var sum = 0.0;
        for (final a in groups[i]) {
          for (final b in groups[j]) {
            sum += alike(a, b);
          }
        }
        final average = sum / (groups[i].length * groups[j].length);
        if (average > best) {
          best = average;
          from = i;
          into = j;
        }
      }
    }
    if (from == null || into == null) break;
    groups = [
      for (var k = 0; k < groups.length; k++)
        if (k == from)
          [...groups[from], ...groups[into]]
        else if (k != into)
          groups[k],
    ];
  }

  final clusters = [
    for (final group in groups)
      TasteCluster(
        artists: [...group]..sort((a, b) => weights[b]!.compareTo(weights[a]!)),
        weight: group.fold(0.0, (sum, a) => sum + weights[a]!),
      ),
  ]..sort((a, b) => b.weight.compareTo(a.weight));
  // A group the person hardly plays is not worth a mix of its own
  final heaviest = clusters.first.weight;
  return clusters
      .where((c) => c.weight >= heaviest * 0.1)
      .take(maxClusters)
      .toList();
}
