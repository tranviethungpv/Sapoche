import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/home_model.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/song_key.dart';

Track t(String id, String artist, [String? title]) => Track(
  videoId: id,
  title: title ?? 'Song $id',
  artist: artist,
  durMs: 200000,
);

HistoryEntry heard(Track track, DateTime now, {int days = 0, int plays = 1}) =>
    HistoryEntry(
      track: track,
      at: now.subtract(Duration(days: days)),
      plays: plays,
    );

void main() {
  final now = DateTime(2026, 9, 30, 20);

  test('nothing is known about a new person', () {
    final home = buildHome(
      recent: const [],
      liked: const [],
      forYou: const [],
      seedLists: const [],
      now: now,
    );
    expect(home.isEmpty, isTrue);
    expect(home.topSeed, isNull);
  });

  test('listen again is what was heard last, in order', () {
    final a = t('a', 'X');
    final b = t('b', 'Y');
    final home = buildHome(
      recent: [heard(a, now), heard(b, now, days: 1)],
      liked: const [],
      forYou: const [],
      seedLists: const [],
      now: now,
    );
    expect(home.listenAgain.map((s) => s.videoId), ['a', 'b']);
  });

  group('mixes', () {
    test(
      'go to the artists heard most, each starting from their best song',
      () {
        final recent = [
          heard(t('a1', 'Adele', 'Hello'), now, days: 2, plays: 3),
          heard(t('a2', 'Adele', 'Skyfall'), now, days: 2, plays: 9),
          heard(t('b1', 'Beck - Topic'), now, days: 1, plays: 4),
          heard(t('c1', 'Coldplay'), now, days: 40, plays: 5),
        ];
        final home = buildHome(
          recent: recent,
          liked: const [],
          forYou: const [],
          seedLists: const [],
          now: now,
        );
        expect(home.mixes.map((m) => m.artist), ['Adele', 'Beck', 'Coldplay']);
        expect(home.mixes.first.seed.videoId, 'a2');
        expect(home.topSeed?.videoId, 'a2');
      },
    );

    test('an old habit counts for less than a fresh one', () {
      final home = buildHome(
        recent: [
          heard(t('old', 'Old Band'), now, days: 120, plays: 10),
          heard(t('new', 'New Band'), now, days: 1, plays: 4),
        ],
        liked: const [],
        forYou: const [],
        seedLists: const [],
        now: now,
      );
      expect(home.mixes.first.artist, 'New Band');
    });

    test('one artist is not enough for mixes', () {
      final home = buildHome(
        recent: [heard(t('a', 'Only'), now, plays: 5)],
        liked: const [],
        forYou: const [],
        seedLists: const [],
        now: now,
      );
      expect(home.mixes, isEmpty);
    });

    test('a liked song counts, and the same artist under two names is one', () {
      final home = buildHome(
        recent: [heard(t('a', 'Adele'), now, plays: 1)],
        liked: [t('b', 'Adele VEVO'), t('c', 'Zed')],
        forYou: const [],
        seedLists: const [],
        now: now,
      );
      expect(home.mixes.map((m) => m.artist), ['Adele', 'Zed']);
    });
  });

  group('forgotten favourites', () {
    test('are liked songs not heard for a month, or never', () {
      final fresh = t('fresh', 'A');
      final stale = t('stale', 'B');
      final never = t('never', 'C');
      final home = buildHome(
        recent: [heard(fresh, now, days: 3), heard(stale, now, days: 45)],
        liked: [fresh, stale, never],
        forYou: const [],
        seedLists: const [],
        now: now,
      );
      expect(home.forgotten.map((s) => s.videoId), ['stale', 'never']);
    });

    test(
      'a video that was heard recently keeps its song from being forgotten',
      () {
        final song = t('song', 'Rick Astley', 'Never Gonna Give You Up');
        final video = t(
          'clip',
          'Rick Astley',
          'Never Gonna Give You Up (Official Video)',
        );
        final home = buildHome(
          recent: [heard(video, now, days: 2)],
          liked: [song],
          forYou: const [],
          seedLists: const [],
          now: now,
        );
        expect(home.forgotten, isEmpty);
      },
    );
  });

  group('because you listened to', () {
    test('lists what is new to the person beside a song they know', () {
      final seed = t('seed', 'X', 'Seed Song');
      final home = buildHome(
        recent: [heard(seed, now), heard(t('known', 'Y'), now)],
        liked: const [],
        forYou: const [],
        seedLists: [
          SeedList(
            seed: 'seed',
            tracks: [t('known', 'Y'), t('n1', 'N'), t('n2', 'N'), t('n3', 'N')],
          ),
        ],
        now: now,
      );
      expect(home.becauseOf.single.seed.title, 'Seed Song');
      expect(home.becauseOf.single.tracks.map((s) => s.videoId), [
        'n1',
        'n2',
        'n3',
      ]);
    });

    test(
      'skips a seed the person no longer has, and lists too short to show',
      () {
        final seed = t('seed', 'X');
        final home = buildHome(
          recent: [heard(seed, now)],
          liked: const [],
          forYou: const [],
          seedLists: [
            SeedList(
              seed: 'gone',
              tracks: [t('a', 'N'), t('b', 'N'), t('c', 'N')],
            ),
            SeedList(seed: 'seed', tracks: [t('a', 'N')]),
          ],
          now: now,
        );
        expect(home.becauseOf, isEmpty);
      },
    );

    test('shows at most two', () {
      final seeds = [for (var i = 0; i < 3; i++) t('s$i', 'X$i')];
      final home = buildHome(
        recent: [for (final s in seeds) heard(s, now)],
        liked: const [],
        forYou: const [],
        seedLists: [
          for (final s in seeds)
            SeedList(
              seed: s.videoId,
              tracks: [for (var i = 0; i < 4; i++) t('${s.videoId}n$i', 'N$i')],
            ),
        ],
        now: now,
      );
      expect(home.becauseOf, hasLength(2));
    });
  });

  test('quick picks are the suggestions, each song once', () {
    final home = buildHome(
      recent: const [],
      liked: const [],
      forYou: [
        t('a', 'X', 'Song'),
        t('b', 'X', 'Song (Official Video)'),
        t('c', 'Y'),
      ],
      seedLists: const [],
      now: now,
    );
    expect(home.quickPicks.map((s) => s.videoId), ['a', 'c']);
  });

  group('quick picks ranked by the lists that vote for them', () {
    SeedList list(String seed, List<Track> tracks) =>
        SeedList(seed: seed, tracks: tracks);

    test(
      'a song beside two loved songs beats one at the top of a single list',
      () {
        final s1 = t('s1', 'A', 'Seed one');
        final s2 = t('s2', 'B', 'Seed two');
        final home = buildHome(
          recent: [heard(s1, now, plays: 5), heard(s2, now, plays: 5)],
          liked: const [],
          forYou: const [],
          seedLists: [
            list('s1', [t('solo', 'P'), t('both', 'Q'), t('x1', 'R')]),
            list('s2', [t('y1', 'S'), t('y2', 'T'), t('both', 'Q')]),
          ],
          now: now,
        );
        final ids = home.quickPicks.map((s) => s.videoId).toList();
        expect(ids.first, 'both');
        expect(ids, containsAll(['solo', 'x1', 'y1', 'y2']));
      },
    );

    test('a seed that is loved more counts for more', () {
      final loved = t('loved', 'A');
      final meh = t('meh', 'B');
      final home = buildHome(
        recent: [heard(loved, now, plays: 20), heard(meh, now, plays: 1)],
        liked: const [],
        forYou: const [],
        seedLists: [
          list('meh', [t('fromMeh', 'P')]),
          list('loved', [t('fromLoved', 'Q')]),
        ],
        now: now,
      );
      expect(home.quickPicks.first.videoId, 'fromLoved');
    });

    test('no artist comes more than twice, and what is known is left out', () {
      final seed = t('seed', 'A');
      final home = buildHome(
        recent: [
          heard(seed, now, plays: 5),
          heard(t('week', 'Z'), now, days: 2),
          heard(t('old', 'Z'), now, days: 30),
        ],
        liked: [t('liked', 'Y')],
        forYou: const [],
        seedLists: [
          list('seed', [
            for (var i = 0; i < 6; i++) t('p$i', 'P'),
            t('week', 'Z'),
            t('liked', 'Y'),
            t('old', 'Z'),
          ]),
        ],
        now: now,
      );
      final ids = home.quickPicks.map((s) => s.videoId).toList();
      expect(ids.where((id) => id.startsWith('p')).length, 2);
      expect(ids, isNot(contains('week')), reason: 'heard this week');
      expect(ids, isNot(contains('liked')), reason: 'already liked');
      expect(ids, contains('old'), reason: 'heard long ago');
    });

    test('three places in ten go to artists the person does not play yet', () {
      final seed = t('seed', 'Known');
      final home = buildHome(
        recent: [heard(seed, now, plays: 9)],
        liked: const [],
        forYou: const [],
        seedLists: [
          list('seed', [
            // Ten artists the person plays come first in the list, then new ones
            for (var i = 0; i < 12; i++) t('k$i', 'Known'),
          ]),
          list('seed', [for (var i = 0; i < 8; i++) t('n$i', 'New$i')]),
        ],
        now: now,
      );
      final picks = home.quickPicks.map((s) => s.videoId).toList();
      // Known is capped at two songs, so most of the list is new anyway; but the new ones come at 3, 6 and 9
      expect(picks.where((id) => id.startsWith('k')).length, 2);
      expect(picks.where((id) => id.startsWith('n')).length, greaterThan(5));
    });

    test(
      'the lists that were not kept leave the native suggestions as they were',
      () {
        final home = buildHome(
          recent: [heard(t('a', 'A'), now)],
          liked: const [],
          forYou: [t('f1', 'X'), t('f2', 'Y')],
          seedLists: const [],
          now: now,
        );
        expect(home.quickPicks.map((s) => s.videoId), ['f1', 'f2']);
      },
    );
  });

  group('a mix for every taste', () {
    /// Two tastes: mornings are Adele, Beck and Cher; nights are Drake and Eminem.
    List<HistoryEntry> listensOf(DateTime now) => [
      for (var d = 1; d <= 8; d++) ...[
        for (final (i, a) in ['Adele', 'Beck', 'Cher'].indexed)
          HistoryEntry(
            track: t('${a.toLowerCase()}${d % 4}', a),
            at: DateTime(now.year, now.month, now.day - 2 * d, 8, 4 * i),
          ),
        for (final (i, a) in ['Drake', 'Eminem'].indexed)
          HistoryEntry(
            track: t('${a.toLowerCase()}${d % 4}', a),
            at: DateTime(now.year, now.month, now.day - 2 * d, 22, 4 * i),
          ),
      ],
    ];

    List<HistoryEntry> aggregated(List<HistoryEntry> listens) {
      final byId = <String, HistoryEntry>{};
      for (final e in listens) {
        final kept = byId[e.track.videoId];
        byId[e.track.videoId] = HistoryEntry(
          track: e.track,
          at: kept == null || e.at.isAfter(kept.at) ? e.at : kept.at,
          plays: (kept?.plays ?? 0) + 1,
        );
      }
      return byId.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    }

    HomeShelves home(DateTime at, {List<SeedList> seedLists = const []}) {
      final listens = listensOf(at);
      return buildHome(
        recent: aggregated(listens),
        liked: const [],
        forYou: const [],
        seedLists: seedLists,
        now: at,
        listens: listens,
      );
    }

    test('each taste gets its own mix, the one played most first', () {
      final built = home(now);
      expect(built.dailyMixes.map((m) => m.number), [1, 2]);
      expect(built.dailyMixes.first.artists.toSet(), {'Adele', 'Beck', 'Cher'});
      expect(built.dailyMixes.last.artists.toSet(), {'Drake', 'Eminem'});
      for (final mix in built.dailyMixes) {
        final taste = mix.artists.map(mainArtist).toSet();
        expect(
          mix.tracks.every((s) => taste.contains(mainArtist(s.artist))),
          isTrue,
        );
      }
    });

    test('songs they do not know are mixed in beside the ones they do', () {
      final fresh = [
        for (var i = 0; i < 6; i++) t('new$i', 'Dua Lipa $i'),
        t('drakeNew', 'Drake', 'A New Drake'),
      ];
      final built = home(
        now,
        seedLists: [SeedList(seed: 'adele1', tracks: fresh)],
      );
      final first = built.dailyMixes.first;
      final ids = first.tracks.map((s) => s.videoId).toSet();
      expect(ids.where((id) => id.startsWith('new')), isNotEmpty);
      expect(
        ids,
        isNot(contains('drakeNew')),
        reason: 'beside a song of the other taste, by an artist of it',
      );
      // Two known songs, then one that is new
      expect(first.tracks[2].videoId.startsWith('new'), isTrue);
    });

    test('the mix is the same all day and another the next day', () {
      final morning = home(DateTime(2026, 9, 30, 7));
      final evening = home(DateTime(2026, 9, 30, 22));
      expect(
        evening.dailyMixes.first.tracks.map((s) => s.videoId),
        morning.dailyMixes.first.tracks.map((s) => s.videoId),
      );
      final tomorrow = home(DateTime(2026, 10, 1, 7));
      expect(
        tomorrow.dailyMixes.first.tracks.map((s) => s.videoId).toList(),
        isNot(morning.dailyMixes.first.tracks.map((s) => s.videoId).toList()),
      );
    });

    test('a taste that has too few songs has no mix', () {
      final built = buildHome(
        recent: [heard(t('a', 'Adele'), now), heard(t('b', 'Beck'), now)],
        liked: const [],
        forYou: const [],
        seedLists: const [],
        now: now,
        listens: [heard(t('a', 'Adele'), now), heard(t('b', 'Beck'), now)],
      );
      expect(built.dailyMixes, isEmpty);
    });

    test('what was blocked is in no mix', () {
      final listens = listensOf(now);
      final built = buildHome(
        recent: aggregated(listens),
        liked: const [],
        forYou: const [],
        seedLists: const [],
        now: now,
        listens: listens,
        blocked: [
          const BlockedItem(kind: 'artist', key: 'adele', label: 'Adele'),
        ],
      );
      final names = built.dailyMixes.expand((m) => m.artists);
      expect(names, isNot(contains('Adele')));
    });

    test('the cover is up to four different pictures', () {
      final mix = DailyMix(
        number: 1,
        artists: const ['A'],
        tracks: [
          for (final thumb in ['a', 'a', 'b', null, 'c', 'd', 'e'])
            Track(
              videoId: 'v${thumb}x',
              title: 't',
              artist: 'A',
              durMs: 1,
              thumb: thumb,
            ),
        ],
      );
      expect(mix.covers, ['a', 'b', 'c', 'd']);
    });
  });

  group('what the person asked not to be offered', () {
    BlockedItem song(String id) =>
        BlockedItem(kind: 'song', key: id, label: id);
    BlockedItem artist(String key) =>
        BlockedItem(kind: 'artist', key: key, label: key);

    test('is left out of every row made of suggestions', () {
      final home = buildHome(
        recent: const [],
        liked: const [],
        forYou: [t('a', 'X'), t('b', 'Y'), t('c', 'Z')],
        seedLists: const [],
        now: now,
        discover: [t('d', 'X'), t('e', 'W')],
        context: ContextMix(
          bucket: 'evening',
          tracks: [t('f', 'Y'), t('g', 'V')],
        ),
        blocked: [song('a'), artist('y')],
      );
      expect(home.quickPicks.map((s) => s.videoId), ['c']);
      expect(home.discover.map((s) => s.videoId), ['d', 'e']);
      expect(home.context.map((s) => s.videoId), ['g']);
      expect(home.contextBucket, 'evening');
    });

    test('does not start a mix or seed a row', () {
      final recent = [
        heard(t('a1', 'Adele'), now, days: 1, plays: 5),
        heard(t('b1', 'Beck'), now, days: 1, plays: 4),
        heard(t('c1', 'Coldplay'), now, days: 1, plays: 3),
      ];
      final home = buildHome(
        recent: recent,
        liked: const [],
        forYou: const [],
        seedLists: [
          SeedList(
            seed: 'a1',
            tracks: [t('x1', 'P'), t('x2', 'Q'), t('x3', 'R')],
          ),
          SeedList(
            seed: 'b1',
            tracks: [t('y1', 'P'), t('y2', 'Q'), t('y3', 'R'), t('y4', 'S')],
          ),
        ],
        now: now,
        blocked: [artist('adele'), song('y2')],
      );
      expect(home.mixes.map((m) => m.artist), ['Beck', 'Coldplay']);
      expect(home.topSeed?.videoId, 'b1');
      expect(home.becauseOf.map((b) => b.seed.videoId), ['b1']);
      expect(home.becauseOf.single.tracks.map((s) => s.videoId), [
        'y1',
        'y3',
        'y4',
      ]);
    });

    test('a person who asks for nothing changes nothing', () {
      final home = buildHome(
        recent: const [],
        liked: const [],
        forYou: [t('a', 'X')],
        seedLists: const [],
        now: now,
      );
      expect(home.quickPicks.map((s) => s.videoId), ['a']);
      expect(home.contextBucket, '');
    });
  });
}
