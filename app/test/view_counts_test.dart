import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

MusicTrack track(String id, {String? stats, String artist = 'Star'}) =>
    MusicTrack(videoId: id, title: 'Song $id', artist: artist, durMs: 1000, stats: stats);

Future<FakeBackend> openHome(
  WidgetTester tester,
  void Function(FakeBackend) prepare, {
  double width = 900,
  String language = 'en',
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 1600);
  addTearDown(tester.view.reset);
  final (backend, _) = await pumpApp(tester, listen: false);
  S.current = language;
  prepare(backend);
  backend.emit(const StateEvent(RoomSnapshot()));
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  return backend;
}

/// The font of a test is twice as wide as the real one: half the size is as wide as a real one is, so what fits on a
/// phone fits here.
void realWidth(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearAllTestValues);
}

void main() {
  tearDown(() => S.current = 'en');

  group('what the controller remembers', () {
    test('the count of a song comes from its own list, else from one that showed it before', () async {
      final backend = FakeBackend()
        ..trendingResult = [
          MusicShelf(title: 'Hits', tracks: [track('seen1111111', stats: '59M plays')]),
        ];
      final music = MusicController(backend);
      expect(music.viewsFor(track('seen1111111')), isNull);
      await music.trending();
      // A song with nothing of its own (a row of the library, the queue, a room) has the one the list showed
      expect(music.viewsFor(const Track(videoId: 'seen1111111', title: 'x', artist: 'y', durMs: 0)), '59M plays');
      expect(music.viewsFor(track('seen1111111', stats: '1.2M views')), '1.2M views');
      expect(music.viewsFor(track('other111111')), isNull);
    });

    test('pages of an album or a playlist, the songs after them and the radio of a song are remembered too', () async {
      final backend = FakeBackend()
        ..collectionResult = CollectionPage(id: 'PL1', title: 'L', tracks: [track('album111111', stats: '9M plays')])
        ..radioResult = SongRadio(tracks: [track('radio111111', stats: '1.8B views · 19M likes')]);
      final music = MusicController(backend);
      await music.collection('PL1');
      await music.radio('x');
      expect(music.seenViews('album111111'), '9M plays');
      expect(music.seenViews('radio111111'), '1.8B views');
      expect(backend.calls.where((c) => c.startsWith('musicViews')), isEmpty);
    });

    test('keeps the last two thousand songs and lets the oldest go', () async {
      final backend = FakeBackend()
        ..trendingResult = [
          MusicShelf(
            title: 'Many',
            tracks: [for (var i = 0; i < 2100; i++) track('id${i.toString().padLeft(9, '0')}', stats: '1M plays')],
          ),
        ];
      final music = MusicController(backend);
      await music.trending();
      expect(music.seenViews('id${'0'.padLeft(9, '0')}'), isNull);
      expect(music.seenViews('id${'99'.padLeft(9, '0')}'), isNull);
      expect(music.seenViews('id${'100'.padLeft(9, '0')}'), '1M plays');
      expect(music.seenViews('id${'2099'.padLeft(9, '0')}'), '1M plays');
    });

    test('says a count in the language the app is in now', () async {
      final music = MusicController(FakeBackend()..trendingResult = [MusicShelf(title: 'Hits', tracks: [track('lang1111111', stats: '2.3M plays')])]);
      await music.trending();
      expect(music.seenViews('lang1111111'), '2.3M plays');
      S.current = 'vi';
      expect(music.seenViews('lang1111111'), '2,3 Tr lượt phát');
    });
  });

  group('a shelf of covers', () {
    List<MusicShelf> shelves() => [
      MusicShelf(
        title: 'Hits',
        tracks: [track('hit11111111', stats: '2.3M plays'), track('hit22222222')],
        playlists: const [Release(id: 'PL1', title: 'Chill Mix', subtitle: 'Anna • 2.2M views')],
      ),
      MusicShelf(title: 'Quiet', tracks: [track('quiet111111')]),
    ];

    testWidgets('has the count on a line of its own after the artist, for a song and for a playlist', (tester) async {
      final backend = await openHome(tester, (b) => b.trendingResult = shelves());
      expect(find.text('2.3M plays'), findsOneWidget);
      expect(find.text('2.2M views'), findsOneWidget);
      // The maker of the playlist stays on the line of the artist, without the count after it
      expect(find.text('Anna'), findsOneWidget);
      expect(tester.getTopLeft(find.text('2.3M plays')).dy, greaterThan(tester.getTopLeft(find.text('Star').first).dy));
      expect(backend.calls.where((c) => c.startsWith('musicViews')), isEmpty);
    });

    testWidgets('is higher by a line only when a card of it has a count', (tester) async {
      await openHome(tester, (b) => b.trendingResult = shelves());
      double height(String of) => tester.getSize(find.ancestor(of: find.text(of), matching: find.byType(ListView)).first).height;
      final counted = height('Song hit11111111');
      final plain = height('Song quiet111111');
      expect(counted, greaterThan(plain));
      expect(counted - plain, lessThan(30));
    });

    testWidgets('says the count in Vietnamese when the app is', (tester) async {
      realWidth(tester);
      await openHome(tester, (b) => b.trendingResult = shelves(), language: 'vi');
      expect(find.text('2,3 Tr lượt phát'), findsOneWidget);
      expect(find.text('2,2 Tr lượt xem'), findsOneWidget);
      expect(find.textContaining('plays'), findsNothing);
      expect(find.textContaining('views'), findsNothing);
    });

    testWidgets('a card too narrow for its count leaves it out whole, never cut', (tester) async {
      await openHome(tester, (b) => b.trendingResult = [
        MusicShelf(title: 'Hits', tracks: [track('hit11111111', stats: '2.3M plays')]),
      ], width: 360);
      // Whole or not there: a count in half would read "2.3M p…"
      for (final e in find.textContaining('M p').evaluate()) {
        expect((e.widget as Text).data, '2.3M plays');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('a playlist of songs with no count of their own', () {
    testWidgets('shows the one a list gave them, and asks nothing for it', (tester) async {
      final backend = await openHome(tester, (b) {
        b.trendingResult = [
          MusicShelf(
            title: 'Featured',
            tracks: [track('seen1111111', stats: '9M plays')],
            playlists: const [Release(id: 'PLabc', title: 'Chill Mix')],
          ),
        ];
        b.collectionResult = CollectionPage(
          id: 'PLabc',
          title: 'Chill Mix',
          kind: 'Playlist',
          owner: 'Anna',
          tracks: [track('seen1111111'), track('new11111111')],
        );
      });
      await tester.tap(find.text('Chill Mix'));
      await tester.pumpAndSettle();
      expect(find.text('Song seen1111111'), findsWidgets);
      expect(find.text('Star · 9M plays'), findsOneWidget, reason: 'the song a list showed; the other has none');
      expect(find.textContaining('plays'), findsOneWidget, reason: 'the row; the shelf is under the page');
      expect(backend.calls.where((c) => c.startsWith('musicViews')), isEmpty);
    });
  });

  group('an album', () {
    final album = CollectionPage(
      id: 'MPREb_album',
      title: 'The Album',
      kind: 'Album',
      owner: 'Zen',
      stats: const ['2 songs', '5M views'],
      tracks: [
        track('a1aaaaaaaaa', stats: '9M plays', artist: 'Zen'),
        track('a2aaaaaaaaa', stats: '800K plays', artist: 'Zen & Friend'),
      ],
    );

    testWidgets('says the counts of its songs and of itself in the language of the app', (tester) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      S.current = 'vi';
      realWidth(tester);
      backend.collectionResult = album;
      backend.emit(const StateEvent(RoomSnapshot()));
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      openCollection(tester.element(find.byType(HomeShell)), id: 'MPREb_album', title: 'x');
      await tester.pumpAndSettle();
      expect(find.text('9 Tr lượt phát'), findsOneWidget, reason: 'by the artist of the album: the count alone');
      expect(find.text('Zen & Friend · 800 N lượt phát'), findsOneWidget, reason: 'by another: the name, then the count');
      expect(find.text('2 songs · 5 Tr lượt xem'), findsOneWidget);
      expect(find.textContaining('plays'), findsNothing);
      expect(find.textContaining('views'), findsNothing);
    });
  });
}
