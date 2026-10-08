import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/home_model.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';

import 'fake_backend.dart';
import 'home_page_test.dart' show openHome, song;

Finder get _scrollable => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 300, scrollable: _scrollable);

MusicTrack _music(String id, String title, String artist, {String? artistId}) =>
    MusicTrack(
      videoId: id,
      title: title,
      artist: artist,
      artistId: artistId,
      durMs: 200000,
    );

/// A person with two tastes: mornings are Adele, Beck and Cher (four songs each), nights are Drake and Eminem.
void _twoTastes(FakeBackend b) {
  final now = DateTime.now();
  final listens = <HistoryEntry>[];
  for (var d = 1; d <= 8; d++) {
    final day = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: 2 * d));
    for (final (i, a) in ['Adele', 'Beck', 'Cher'].indexed) {
      listens.add(
        HistoryEntry(
          track: song('${a.toLowerCase()}${d % 4}aaaa', 'Song ${d % 4}', a),
          at: day.add(Duration(hours: 8, minutes: 4 * i)),
        ),
      );
    }
    for (final (i, a) in ['Drake', 'Eminem'].indexed) {
      listens.add(
        HistoryEntry(
          track: song('${a.toLowerCase()}${d % 4}aaaa', 'Song ${d % 4}', a),
          at: day.add(Duration(hours: 22, minutes: 4 * i)),
        ),
      );
    }
  }
  b.listenResults = listens;
  final byId = <String, HistoryEntry>{};
  for (final e in listens) {
    final kept = byId[e.track.videoId];
    byId[e.track.videoId] = HistoryEntry(
      track: e.track,
      at: kept == null || e.at.isAfter(kept.at) ? e.at : kept.at,
      plays: (kept?.plays ?? 0) + 1,
    );
  }
  b.recentSongs = byId.values.toList()..sort((a, b) => b.at.compareTo(a.at));
}

void main() {
  group('moods', () {
    MusicHome home() => const MusicHome(
      chips: [
        MoodChip(label: 'Relax', params: 'p-relax'),
        MoodChip(label: 'Workout', params: 'p-work'),
      ],
    );

    testWidgets('are pills on top of the page', (tester) async {
      await openHome(tester, prepare: (b) => b.homeResult = home());
      expect(find.text('Relax'), findsOneWidget);
      expect(find.text('Workout'), findsOneWidget);
    });

    testWidgets('are not there without a network', (tester) async {
      await openHome(tester, prepare: (b) => b.musicFailWith = StateError('x'));
      expect(find.text('Relax'), findsNothing);
    });

    testWidgets('a touch opens the playlists that suit the mood', (
      tester,
    ) async {
      final backend = await openHome(
        tester,
        prepare: (b) {
          b.homeResult = home();
          b.moodResults['p-relax'] = MusicHome(
            shelves: [
              MusicShelf(
                title: 'Chilled',
                playlists: [Release(id: 'PLchill', title: 'Slow Evening')],
              ),
            ],
          );
        },
      );
      await tester.tap(find.byKey(const ValueKey('mood-p-relax')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicHome p-relax'));
      expect(find.text('Chilled'), findsOneWidget);
      expect(find.text('Slow Evening'), findsOneWidget);
      // Back to the page it came from
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Relax'), findsOneWidget);
    });

    testWidgets('a mood that cannot be loaded says so and tries again', (
      tester,
    ) async {
      final backend = await openHome(
        tester,
        prepare: (b) => b.homeResult = home(),
      );
      backend.musicFailWith = StateError('offline');
      await tester.tap(find.byKey(const ValueKey('mood-p-work')));
      await tester.pumpAndSettle();
      expect(find.text('This mood could not be loaded.'), findsOneWidget);
      backend.musicFailWith = null;
      backend.moodResults['p-work'] = const MusicHome(
        shelves: [
          MusicShelf(
            title: 'Gym',
            playlists: [Release(id: 'PLgym', title: 'Heavy Lifting')],
          ),
        ],
      );
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Heavy Lifting'), findsOneWidget);
    });
  });

  testWidgets('what was heard last is tiles on top, a touch plays it', (
    tester,
  ) async {
    final anna = song('annaaaaaaaa', 'Hello', 'Adele');
    final beck = song('beckaaaaaaa', 'Loser', 'Beck');
    final backend = await openHome(
      tester,
      prepare: (b) => b.recentSongs = [
        HistoryEntry(track: anna, at: DateTime.now()),
        HistoryEntry(track: beck, at: DateTime.now()),
      ],
    );
    await tester.tap(find.byKey(ValueKey('jump-${beck.videoId}')));
    await tester.pump();
    expect(
      backend.calls,
      containsAllInOrder(['clear', 'addMany ${beck.videoId} next=false']),
    );
  });

  group('the mixes made for the person', () {
    testWidgets('are one for each taste, and a touch plays one', (
      tester,
    ) async {
      final backend = await openHome(tester, prepare: _twoTastes);
      expect(find.text('Made for you'), findsOneWidget);
      expect(find.byKey(const ValueKey('mix-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('mix-2')), findsOneWidget);
      expect(find.textContaining(' and more'), findsOneWidget);
      expect(
        find.textContaining(RegExp('^(Drake and Eminem|Eminem and Drake)\$')),
        findsOneWidget,
      );
      // The mixes of the artists are a row of radios further down, not the same thing twice
      expect(find.text('Mixed for you'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mix-2')));
      await tester.pump();
      final added = backend.calls.firstWhere((c) => c.startsWith('addMany'));
      expect(added, contains('drake'));
      expect(added, isNot(contains('adele')));
      expect(backend.calls, contains('clear'));
    });

    testWidgets('go on the queue in a room instead of taking its place', (
      tester,
    ) async {
      final backend = await openHome(tester, prepare: _twoTastes, inRoom: true);
      await tester.tap(find.byKey(const ValueKey('mix-1')));
      await tester.pump();
      expect(backend.calls, isNot(contains('clear')));
      expect(backend.calls.where((c) => c.startsWith('addMany')), isNotEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('are not there for somebody who has heard nothing', (
      tester,
    ) async {
      await openHome(tester);
      expect(find.text('Made for you'), findsNothing);
    });
  });

  testWidgets('the latest release of an artist the person plays is a shelf', (
    tester,
  ) async {
    final year = DateTime.now().year;
    final anna = song('annaaaaaaaa', 'Hello', 'Adele');
    final backend = await openHome(
      tester,
      prepare: (b) {
        b.recentSongs = [
          HistoryEntry(track: anna, at: DateTime.now(), plays: 5),
          HistoryEntry(
            track: song('beckaaaaaaa', 'Loser', 'Beck'),
            at: DateTime.now(),
          ),
        ];
        b.radioResult = SongRadio(
          tracks: [_music(anna.videoId, 'Hello', 'Adele', artistId: 'UCadele')],
        );
        b.artistResult = ArtistPage(
          id: 'UCadele',
          name: 'Adele',
          singles: [
            Release(
              id: 'MPREnew',
              title: 'Brand New Single',
              subtitle: 'Single • $year',
            ),
          ],
        );
      },
    );
    await _scrollTo(tester, find.text('Latest from your artists'));
    expect(find.text('Brand New Single'), findsOneWidget);
    expect(find.text('Adele · $year'), findsOneWidget);
    expect(backend.calls, contains('musicArtist UCadele'));
  });

  testWidgets('the charts of the country are playlists and its top artists', (
    tester,
  ) async {
    await openHome(
      tester,
      prepare: (b) => b.chartsResult = [
        MusicShelf(
          title: 'Video charts',
          playlists: [Release(id: 'PLtop', title: 'Top 100 Vietnam')],
        ),
        MusicShelf(
          title: 'Top artists',
          artists: [ArtistCard(id: 'UC1', name: 'Number One')],
        ),
      ],
    );
    await _scrollTo(tester, find.text('Top 100 Vietnam'));
    expect(find.text('Charts'), findsOneWidget);
    await _scrollTo(tester, find.text('Number One'));
    expect(find.text('Top artists'), findsOneWidget);
  });

  testWidgets(
    'a playlist the charts row shows is not shown again as featured',
    (tester) async {
      await openHome(
        tester,
        prepare: (b) {
          b.chartsResult = [
            MusicShelf(
              title: 'Video charts',
              playlists: [Release(id: 'PLtop', title: 'Top 100 Vietnam')],
            ),
          ];
          b.trendingResult = [
            MusicShelf(
              title: 'Featured playlists for you',
              playlists: [
                Release(id: 'PLtop', title: 'Top 100 Vietnam'),
                Release(id: 'PLother', title: 'Something Else'),
              ],
            ),
            MusicShelf(
              title: 'Only charted',
              playlists: [Release(id: 'PLtop', title: 'Top 100 Vietnam')],
            ),
          ];
        },
      );
      await _scrollTo(tester, find.text('Something Else'));
      expect(find.text('Top 100 Vietnam'), findsOneWidget);
      expect(find.text('Featured playlists for you'), findsOneWidget);
      expect(find.text('Only charted'), findsNothing);
    },
  );

  group('the order of the rows learns what is touched', () {
    /// Counts for every part of the day, so the test does not depend on the hour it runs at.
    Map<String, Object> habit(Map<String, List<int>> counts) => {
      'shelf_stats': jsonEncode({
        for (final part in ['morning', 'afternoon', 'evening', 'night'])
          part: counts,
      }),
    };

    List<String> heardSongs(FakeBackend b) {
      b.recentSongs = [
        for (var i = 0; i < 12; i++)
          HistoryEntry(
            track: song('song${i}aaaaaaa', 'Song $i', 'Artist ${i % 3}'),
            at: DateTime.now().subtract(Duration(hours: i)),
          ),
      ];
      b.discoverSongs = [song('newaaaaaaaa', 'Unheard', 'Newcomer')];
      b.forYouSongs = [song('qpaaaaaaaaa', 'A Quick Pick', 'Someone')];
      return const [];
    }

    testWidgets(
      'a new person sees the rows in the order the page was made in',
      (tester) async {
        await openHome(tester, prepare: heardSongs);
        expect(
          tester.getTopLeft(find.text('Quick picks')).dy,
          lessThan(tester.getTopLeft(find.text('Try something new')).dy),
        );
      },
    );

    testWidgets('a row that is always touched comes before the rest', (
      tester,
    ) async {
      await openHome(
        tester,
        prepare: heardSongs,
        prefs: habit({
          'discover': [60, 50],
          'quick': [60, 0],
        }),
      );
      expect(
        tester.getTopLeft(find.text('Try something new')).dy,
        lessThan(tester.getTopLeft(find.text('Quick picks')).dy),
      );
    });

    testWidgets('rows that are seen and touched are counted, and kept', (
      tester,
    ) async {
      await openHome(tester, prepare: heardSongs);
      await tester.tap(find.text('A Quick Pick'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('shelf_stats')!) as Map;
      final part = stored[dayPartOf(DateTime.now())] as Map;
      expect(part['quick'], [1, 1]);
      expect((part['discover'] as List).first, 1, reason: 'seen, not touched');
      expect((part['discover'] as List).last, 0);
    });

    testWidgets('a row is counted once however often it scrolls out of sight', (
      tester,
    ) async {
      await openHome(tester, prepare: heardSongs);
      await _scrollTo(tester, find.text('Try something new'));
      await tester.drag(_scrollable, const Offset(0, 900));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Try something new'));
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('shelf_stats')!) as Map;
      final part = stored[dayPartOf(DateTime.now())] as Map;
      expect((part['discover'] as List).first, 1);
    });

    testWidgets('a drag along a row is not a touch', (tester) async {
      await openHome(tester, prepare: heardSongs);
      await tester.drag(find.text('A Quick Pick'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('shelf_stats')!) as Map;
      final part = stored[dayPartOf(DateTime.now())] as Map;
      expect((part['quick'] as List).last, 0);
    });
  });
}
