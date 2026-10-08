import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/song_key.dart';
import 'package:sapoche/data/taste_clusters.dart';

Track t(String id, String artist) =>
    Track(videoId: id, title: 'Song $id', artist: artist, durMs: 200000);

void main() {
  final day = DateTime(2026, 10, 1, 8);

  /// One session: [artists] heard a few minutes apart, starting at [start].
  List<HistoryEntry> session(DateTime start, List<String> artists) => [
    for (final (i, a) in artists.indexed)
      HistoryEntry(
        track: t('$a$i${start.millisecondsSinceEpoch}', a),
        at: start.add(Duration(minutes: 4 * i)),
      ),
  ];

  Map<String, double> weigh(Iterable<String> artists) => {
    for (final (i, a) in artists.indexed) mainArtist(a): 10.0 - i,
  };

  test('nothing is played, nothing is grouped', () {
    expect(clusterTaste(listens: const [], weights: const {}), isEmpty);
    expect(
      clusterTaste(listens: const [], weights: {'x': 0}),
      isEmpty,
      reason: 'an artist with no weight is not a taste',
    );
  });

  test('artists played in the same sessions are one taste, others another', () {
    // Mornings are Adele, Beck and Cher; nights are Drake and Eminem
    final listens = <HistoryEntry>[
      for (var d = 0; d < 6; d++) ...[
        ...session(day.add(Duration(days: 2 * d)), ['Adele', 'Beck', 'Cher']),
        ...session(day.add(Duration(days: 2 * d, hours: 13)), [
          'Drake',
          'Eminem',
        ]),
      ],
    ];
    final clusters = clusterTaste(
      listens: listens,
      weights: weigh(['Adele', 'Beck', 'Cher', 'Drake', 'Eminem']),
    );
    expect(clusters.length, 2);
    expect(clusters.first.artists.toSet(), {'adele', 'beck', 'cher'});
    expect(clusters.last.artists.toSet(), {'drake', 'eminem'});
    expect(
      clusters.first.artists.first,
      'adele',
      reason: 'the best loved of a group first',
    );
    expect(clusters.first.weight, greaterThan(clusters.last.weight));
  });

  test('a pause of three quarters of an hour ends a session', () {
    // Adele and Drake are always an hour apart: never in one session
    final listens = <HistoryEntry>[
      for (var d = 0; d < 5; d++) ...[
        ...session(day.add(Duration(days: d)), ['Adele']),
        ...session(day.add(Duration(days: d, hours: 1)), ['Drake']),
      ],
    ];
    final clusters = clusterTaste(
      listens: listens,
      weights: weigh(['Adele', 'Drake']),
    );
    expect(clusters.map((c) => c.artists), [
      ['adele'],
      ['drake'],
    ]);
  });

  test('artists that are never played together stay on their own', () {
    final listens = <HistoryEntry>[
      for (var d = 0; d < 4; d++)
        ...session(day.add(Duration(days: d)), [
          ['Adele', 'Beck', 'Cher'][d % 3],
        ]),
    ];
    final clusters = clusterTaste(
      listens: listens,
      weights: weigh(['Adele', 'Beck', 'Cher']),
    );
    expect(clusters.every((c) => c.artists.length == 1), isTrue);
  });

  test('a taste is joined in one piece, not drawn into a chain', () {
    // A with B, B with C, but A and C never: the average likeness of the three is too low to join them all
    final listens = <HistoryEntry>[
      for (var d = 0; d < 5; d++) ...[
        ...session(day.add(Duration(days: 3 * d)), ['Adele', 'Beck']),
        ...session(day.add(Duration(days: 3 * d + 1)), ['Beck', 'Cher']),
        ...session(day.add(Duration(days: 3 * d + 2)), ['Cher']),
      ],
    ];
    final clusters = clusterTaste(
      listens: listens,
      weights: weigh(['Beck', 'Adele', 'Cher']),
    );
    expect(clusters.any((c) => c.artists.length == 3), isFalse);
  });

  test('only the heaviest groups come back, and not those hardly played', () {
    final listens = <HistoryEntry>[
      for (var d = 0; d < 5; d++) ...[
        ...session(day.add(Duration(days: d)), ['A']),
        ...session(day.add(Duration(days: d, hours: 3)), ['B']),
        ...session(day.add(Duration(days: d, hours: 6)), ['C']),
        ...session(day.add(Duration(days: d, hours: 9)), ['D']),
        ...session(day.add(Duration(days: d, hours: 12)), ['E']),
      ],
    ];
    final weights = {'a': 10.0, 'b': 9.0, 'c': 8.0, 'd': 7.0, 'e': 6.0};
    expect(clusterTaste(listens: listens, weights: weights).length, 4);
    expect(
      clusterTaste(listens: listens, weights: weights, maxClusters: 2).length,
      2,
    );
    final lopsided = {...weights, 'e': 0.5};
    final kept = clusterTaste(listens: listens, weights: lopsided);
    expect(kept.expand((c) => c.artists), isNot(contains('e')));
  });

  test('the order the listens come in does not matter', () {
    final listens = <HistoryEntry>[
      for (var d = 0; d < 4; d++) ...[
        ...session(day.add(Duration(days: 2 * d)), ['Adele', 'Beck']),
        ...session(day.add(Duration(days: 2 * d, hours: 13)), ['Drake']),
      ],
    ];
    final weights = weigh(['Adele', 'Beck', 'Drake']);
    List<List<String>> shape(List<HistoryEntry> l) => [
      for (final c in clusterTaste(listens: l, weights: weights)) c.artists,
    ];
    expect(shape(listens.reversed.toList()), shape(listens));
  });
}
