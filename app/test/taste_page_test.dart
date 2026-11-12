import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';

import 'fake_backend.dart';
import 'home_page_test.dart' show musicSong, openHome, song;

const _profile = TasteProfile(
  artists: [
    ArtistRank(key: 'adele', label: 'Adele', score: 10),
    ArtistRank(key: 'beck', label: 'Beck', score: 5),
    ArtistRank(key: 'cher', label: 'Cher', score: 0),
  ],
);

/// Opens Settings > Suggestions.
Future<void> openSuggestions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('settings-suggestions')));
  await tester.pumpAndSettle();
}

/// Scrolls the settings page until [finder] shows.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  group('the taste on the suggestions page', () {
    testWidgets('says once, above the artists, what the two buttons at the end of a row are', (tester) async {
      await openHome(tester, prepare: (b) => b.tasteProfileResult = _profile);
      await openSuggestions(tester);
      final legend = find.byKey(const ValueKey('taste-legend'));
      expect(legend, findsOneWidget);
      expect(find.descendant(of: legend, matching: find.text('Suggest less')), findsOneWidget);
      expect(find.descendant(of: legend, matching: find.text('Block')), findsOneWidget);
    });

    testWidgets('shows the artists with bars, and Suggest less toggles the mark', (tester) async {
      final b = await openHome(tester, prepare: (b) => b.tasteProfileResult = _profile);
      await openSuggestions(tester);
      expect(find.byKey(const ValueKey('taste-artist-adele')), findsOneWidget);
      expect(find.byKey(const ValueKey('taste-artist-beck')), findsOneWidget);
      // An artist with nothing in their favour is not listed
      expect(find.byKey(const ValueKey('taste-artist-cher')), findsNothing);
      expect(find.byKey(const ValueKey('taste-bar')), findsNWidgets(2));
      final bars = tester.widgetList<LinearProgressIndicator>(find.byKey(const ValueKey('taste-bar'))).toList();
      expect(bars.map((e) => e.value), [1.0, 0.5]);

      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('taste-artist-adele')), matching: find.byTooltip('Suggest less')),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('tasteMark quiet_artist adele on=true'));
    });

    testWidgets('Suggest less on an artist already quiet takes the mark off', (tester) async {
      final b = await openHome(
        tester,
        prepare: (b) => b.tasteProfileResult = TasteProfile(
          artists: _profile.artists,
          marks: const [TasteMark(kind: TasteMarks.quietArtist, key: 'adele', label: 'Adele')],
        ),
      );
      await openSuggestions(tester);
      expect(find.text('Fewer suggestions'), findsWidgets);
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('taste-artist-adele')), matching: find.byTooltip('Suggest less')),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('tasteMark quiet_artist adele on=false'));
    });

    testWidgets('Block blocks the artist', (tester) async {
      final b = await openHome(tester, prepare: (b) => b.tasteProfileResult = _profile);
      await openSuggestions(tester);
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('taste-artist-beck')), matching: find.byTooltip('Block')),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('block artist Beck'));
    });

    testWidgets('says so when there is nothing to show yet', (tester) async {
      await openHome(tester, prepare: (b) => b.tasteProfileResult = const TasteProfile());
      await openSuggestions(tester);
      expect(find.text('Listen to a few songs and your taste shows up here'), findsOneWidget);
    });

    testWidgets('the share switch tells the native side', (tester) async {
      final b = await openHome(tester);
      await openSuggestions(tester);
      final toggle = find.byKey(const ValueKey('share-taste-switch'));
      await reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(b.calls, contains('shareTaste false'));
    });

    testWidgets('a mark told to the taste is listed and taken off with a touch', (tester) async {
      final b = await openHome(
        tester,
        prepare: (b) => b.tasteProfileResult = TasteProfile(
          marks: [
            const TasteMark(kind: TasteMarks.quietArtist, key: 'beck', label: 'Beck'),
            const TasteMark(kind: TasteMarks.quietSong, key: 'vid1aaaaaaa', label: 'Loser'),
            TasteMark(
              kind: TasteMarks.starter,
              key: 'vid2aaaaaaa',
              label: TasteMarks.starterLabel(song('vid2aaaaaaa', 'Hello', 'Adele')),
            ),
          ],
        ),
      );
      await openSuggestions(tester);
      final row = find.byKey(const ValueKey('mark-quiet_song-vid1aaaaaaa'));
      await reveal(tester, row);
      expect(find.text('Loser'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-starter-vid2aaaaaaa')), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(b.calls, contains('tasteMark quiet_song vid1aaaaaaa on=false'));
    });
  });

  group('the song menu', () {
    Future<FakeBackend> openMenu(WidgetTester tester, {String artist = 'Adele'}) async {
      final b = await openHome(tester, prepare: (b) => b.discoverSongs = [song('annaaaaaaaa', 'Hello', artist)]);
      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      return b;
    }

    testWidgets('can leave the song out of the taste', (tester) async {
      final b = await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('not-counted-song')));
      await tester.pumpAndSettle();
      expect(b.calls, contains('tasteMark quiet_song annaaaaaaaa on=true'));
      expect(find.text('Got it, it won’t count'), findsOneWidget);
    });

    testWidgets('can suggest less of the artist', (tester) async {
      final b = await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('suggest-less-artist')));
      await tester.pumpAndSettle();
      expect(b.calls, contains('tasteMark quiet_artist adele on=true'));
      expect(find.text('Got it, fewer suggestions of this artist'), findsOneWidget);
    });

    testWidgets('has no artist choices for a song without an artist', (tester) async {
      await openMenu(tester, artist: '');
      expect(find.byKey(const ValueKey('not-counted-song')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggest-less-artist')), findsNothing);
    });
  });

  group('the starter sheet', () {
    const charts = [
      MusicShelf(
        title: 'Top artists',
        artists: [
          ArtistCard(id: 'UCa', name: 'Adele'),
          ArtistCard(id: 'UCb', name: 'Beck'),
          // On another shelf too
          ArtistCard(id: 'UCa', name: 'Adele'),
        ],
      ),
    ];

    testWidgets('puts the best known song of each artist picked among the starter songs', (tester) async {
      final b = await openHome(
        tester,
        prepare: (b) {
          b.chartsResult = charts;
          b.artistResult = ArtistPage(id: 'UCa', name: 'Adele', topSongs: [musicSong('hellooooooo', 'Hello', 'Adele')]);
        },
      );
      await tester.tap(find.byKey(const ValueKey('pick-artists')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('starter-artist-UCa')), findsOneWidget);
      expect(find.byKey(const ValueKey('starter-artist-UCb')), findsOneWidget);
      FilledButton start() => tester.widget<FilledButton>(find.byKey(const ValueKey('starter-start')));
      expect(start().onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('starter-artist-UCa')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(start().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('starter-start')));
      await tester.pumpAndSettle();

      expect(b.calls, contains('musicArtist UCa'));
      expect(b.calls, contains('tasteMark starter hellooooooo on=true'));
      expect(b.calls, contains('refreshSuggestions'));
      // The sheet is gone
      expect(find.byKey(const ValueKey('starter-start')), findsNothing);
    });

    testWidgets('says so when none of the artists could be started', (tester) async {
      final b = await openHome(
        tester,
        prepare: (b) {
          b.chartsResult = charts;
          // An artist page with no songs
          b.artistResult = const ArtistPage(id: 'UCa', name: 'Adele');
        },
      );
      await tester.tap(find.byKey(const ValueKey('pick-artists')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('starter-artist-UCb')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('starter-start')));
      await tester.pumpAndSettle();
      expect(b.calls.where((c) => c.startsWith('tasteMark')), isEmpty);
      expect(find.textContaining('Could not start'), findsOneWidget);
    });

    testWidgets('says so when the charts cannot be loaded', (tester) async {
      await openHome(
        tester,
        prepare: (b) => b.musicFailWith = Exception('offline'),
      );
      await tester.tap(find.byKey(const ValueKey('pick-artists')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load artists'), findsOneWidget);
    });

    testWidgets('searches artists by name and keeps the ones picked', (tester) async {
      final b = await openHome(
        tester,
        prepare: (b) {
          b.chartsResult = charts;
          b.searchPageResult = const SearchResults(
            chips: [SearchChip(label: 'Artists', params: 'ARTISTS')],
          );
          b.searchPageResults['ARTISTS'] = const SearchResults(
            items: [SearchItem(kind: 'artist', id: 'UCz', title: 'Zaz')],
          );
        },
      );
      await tester.tap(find.byKey(const ValueKey('pick-artists')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('starter-artist-UCa')));
      await tester.enterText(find.byKey(const ValueKey('starter-field')), 'zaz');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(b.calls, contains('musicSearchPage ARTISTS zaz'));
      expect(find.byKey(const ValueKey('starter-artist-UCz')), findsOneWidget);
      expect(find.byKey(const ValueKey('starter-artist-UCa')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('starter-start'))).onPressed, isNotNull);
    });
  });
}
