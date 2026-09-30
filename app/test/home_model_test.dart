import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/home_model.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/music_models.dart';

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
}
