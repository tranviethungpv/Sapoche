import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/format.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/search_page.dart';
import 'package:sapoche/ui/widgets/marquee_text.dart';
import 'package:sapoche/ui/widgets/artwork.dart';
import 'package:sapoche/ui/widgets/music_shelf.dart';
import 'package:sapoche/ui/widgets/volume_bar.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

const _song = MusicTrack(
  videoId: 'video0',
  title: 'Song 0',
  artist: 'Artist 0',
  durMs: 200000,
  artistId: 'UC1',
  isSong: true,
);

/// The full player, opened on the first of three songs, after [before] has had the app to itself.
Future<FakeBackend> _openPlayer(
  WidgetTester tester, {
  Future<void> Function(FakeBackend backend, MusicController music)? before,
  double width = 800,
  String language = 'en',
  RoomSnapshot? room,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 1400);
  addTearDown(tester.view.reset);
  final (backend, _) = await pumpApp(tester);
  S.current = language;
  backend.radioResult = const SongRadio(tracks: [_song]);
  final music = AppScope.of(tester.element(find.byType(Scaffold).first)).music;
  await before?.call(backend, music);
  backend.emit(StateEvent(room ?? sampleRoom()));
  backend.emit(
    const PositionEvent(
      PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tapMiniPlayer(tester);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  return backend;
}

void main() {
  tearDown(() => S.current = 'en');

  group('one number of plays for a song', () {
    SearchResults found(String stats) => SearchResults(
      items: [
        SearchItem(
          kind: 'song',
          id: 'video0',
          title: 'Song 0',
          track: MusicTrack(
            videoId: 'video0',
            title: 'Song 0',
            artist: 'Artist 0',
            durMs: 0,
            stats: stats,
            isSong: true,
          ),
        ),
      ],
    );

    testWidgets('the player says what the search said and asks for nothing', (
      tester,
    ) async {
      final backend = await _openPlayer(
        tester,
        before: (backend, music) async {
          backend.views['video0'] = 301000;
          backend.searchPageResult = found('59M plays');
          await music.searchPage('song');
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(' · 59M plays'), findsOneWidget);
      expect(backend.calls, isNot(contains('musicViews video0')));
    });

    testWidgets(
      'in Vietnamese, in a narrow line, the count is left out whole, not shortened',
      (tester) async {
        await _openPlayer(
          tester,
          language: 'vi',
          // The font of a test is twice as wide as a real one: there is room for the whole count only in a wide window
          width: 700,
          before: (backend, music) async {
            backend.searchPageResult = found('5.4M plays');
            await music.searchPage('song');
          },
        );
        // "5,4 Tr" without its word reads as a number of nothing: the count is whole or it is not there
        expect(find.textContaining('5,4 Tr'), findsNothing);
      },
    );

    test('a count without its word', () {
      expect(shortViews('5.4M plays'), '5.4M');
      expect(shortViews('1.8B views'), '1.8B');
      expect(shortViews('1.2K'), '1.2K');
      S.current = 'vi';
      expect(shortViews('5,4 Tr lượt phát'), '5,4 Tr');
    });
  });

  group('the artist line of the player', () {
    testWidgets('the artist is a link to their page', (tester) async {
      final backend = await _openPlayer(tester);
      backend.artistResult = const ArtistPage(id: 'UC1', name: 'Artist 0');
      await tester.tap(
        find
            .descendant(
              of: find.byType(Scaffold).last,
              matching: find.byType(MarqueeText),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicArtist UC1'));
    });

    testWidgets('the count leaves before the name starts to move', (
      tester,
    ) async {
      final backend = await _openPlayer(
        tester,
        language: 'vi',
        // Narrow: the font of a test is twice as wide as a real one
        width: 220,
        before: (backend, music) async {
          backend.searchPageResult = SearchResults(
            items: [
              const SearchItem(
                kind: 'song',
                id: 'video0',
                title: 'Song 0',
                track: MusicTrack(
                  videoId: 'video0',
                  title: 'Song 0',
                  artist: 'Artist 0',
                  durMs: 0,
                  stats: '5.4M plays',
                  isSong: true,
                ),
              ),
            ],
          );
          await music.searchPage('song');
        },
      );
      expect(backend.calls, isNot(contains('musicViews video0')));
      expect(find.textContaining('lượt'), findsNothing);
    });
  });

  group('an empty list of the library', () {
    testWidgets('says what to do and offers to look for songs', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();

      expect(find.text(S.noLikedTitle), findsOneWidget);
      expect(find.text(S.noLikedBody), findsOneWidget);
      await tester.tap(find.text(S.findSongs));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
    });
  });

  group('the sync pill of the player', () {
    Future<void> room(
      WidgetTester tester, {
      required List<Member> members,
      PlayerPosition position = const PlayerPosition(
        playing: true,
        positionMs: 4000,
        durationMs: 200000,
        driftMs: 43,
      ),
    }) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(members: members)));
      backend.emit(PositionEvent(position));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tapMiniPlayer(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    const me = Member(id: 'me', name: 'Anna', ready: true);
    const other = Member(id: 'b', name: 'Binh', ready: true);

    testWidgets('says nothing when nobody else is listening', (tester) async {
      await room(tester, members: const [me]);
      expect(find.textContaining('In sync'), findsNothing);
      expect(find.textContaining(' ms'), findsNothing);
    });

    testWidgets('says it in words, and the number is in the list of members', (
      tester,
    ) async {
      await room(tester, members: const [me, other]);
      expect(find.text('In sync'), findsOneWidget);
      expect(find.textContaining(' ms'), findsNothing);

      await tester.tap(find.text('In sync'));
      await tester.pumpAndSettle();
      expect(find.text('+43 ms'), findsOneWidget);
      expect(find.text('Anna (You)'), findsOneWidget);
    });

    testWidgets(
      'a weak network is a word on the pill and seconds in the list',
      (tester) async {
        await room(
          tester,
          members: const [me, other],
          position: const PlayerPosition(
            playing: true,
            positionMs: 4000,
            durationMs: 200000,
            driftMs: 0,
            weak: true,
            lagMs: 900,
          ),
        );
        expect(find.text('Weak network'), findsOneWidget);
        expect(find.textContaining('behind'), findsNothing);

        await tester.tap(find.text('Weak network'));
        await tester.pumpAndSettle();
        expect(find.text('0.9 s behind'), findsOneWidget);
      },
    );
  });

  group('the queue panel of the player', () {
    Future<void> openQueue(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Up next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('names its three buttons and gives the volume bar up', (
      tester,
    ) async {
      // The font of a test is twice as wide as a real one: the three words fit with the text a little smaller
      tester.platformDispatcher.textScaleFactorTestValue = 0.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _openPlayer(tester, room: sampleRoom(roomAutoplay: true));
      expect(find.byType(VolumeBar), findsOneWidget);
      await openQueue(tester);
      for (final name in ['Shuffle', 'Repeat', 'Autoplay']) {
        expect(find.text(name), findsWidgets, reason: name);
      }
      expect(find.byType(VolumeBar), findsNothing);

      await tester.tap(find.byTooltip('Up next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(VolumeBar), findsOneWidget);
    });

    testWidgets('in Vietnamese, on a narrow phone, the three keep their icons and no word, all together', (
      tester,
    ) async {
      await _openPlayer(
        tester,
        width: 360,
        language: 'vi',
        room: sampleRoom(roomAutoplay: true),
      );
      await tester.tap(find.byTooltip('Tiếp theo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // No pill has its word, instead of the longest one being drawn smaller than the others; the tooltips name them
      expect(find.text('Trộn bài'), findsNothing);
      expect(find.text('Lặp lại'), findsNothing);
      expect(find.descendant(of: find.byTooltip('Tự động phát'), matching: find.text('Tự động phát')), findsNothing);
      expect(find.byTooltip('Tự động phát'), findsOneWidget);
    });
  });

  group('the menu of a song', () {
    const withAlbum = MusicTrack(
      videoId: 'video0',
      title: 'Song 0',
      artist: 'Artist 0',
      durMs: 200000,
      artistId: 'UC1',
      album: 'The Album',
      albumId: 'MPREb_1',
      isSong: true,
    );

    Future<FakeBackend> phone(WidgetTester tester) async {
      final backend = await _openPlayer(tester, width: 400);
      backend.radioResult = const SongRadio(tracks: [withAlbum]);
      await tester.tap(
        find.descendant(
          of: find.byType(Scaffold).last,
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
      );
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('on a phone is a sheet with the song at its head, and icons', (
      tester,
    ) async {
      await phone(tester);
      // The title is on the player and, over it, at the head of the sheet
      expect(find.text('Song 0'), findsWidgets);
      expect(find.byType(BottomSheet), findsOneWidget);
      for (final line in [
        'Song info',
        'Go to artist',
        'Go to album',
        'Add to playlist',
        'Share',
        'Download',
        'Not interested',
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      expect(find.byIcon(Icons.album_outlined), findsOneWidget);
      // What the person is least likely to want comes last
      expect(
        tester.getTopLeft(find.text('Not interested')).dy,
        greaterThan(tester.getTopLeft(find.text('Download')).dy),
      );
    });

    testWidgets('Share sends the name and a link that opens the song', (
      tester,
    ) async {
      final backend = await phone(tester);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        contains(
          'share Song 0 · Artist 0\nhttps://music.youtube.com/watch?v=video0',
        ),
      );
    });

    testWidgets('Go to album opens the album of the song', (tester) async {
      final backend = await phone(tester);
      await tester.tap(find.text('Go to album'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicCollection MPREb_1'));
    });

    testWidgets('on a song without an album it says so', (tester) async {
      final backend = await phone(tester);
      backend.radioResult = const SongRadio(
        tracks: [
          MusicTrack(
            videoId: 'video0',
            title: 'Song 0',
            artist: 'Artist 0',
            durMs: 200000,
          ),
        ],
      );
      await tester.tap(find.text('Go to album'));
      await tester.pumpAndSettle();
      expect(find.text('This song is not on an album'), findsOneWidget);
    });
  });

  group('a shelf of videos', () {
    MusicTrack track(String id, {required bool song}) => MusicTrack(
      videoId: id,
      title: 'T $id',
      artist: 'A',
      durMs: 1000,
      thumb: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      isSong: song,
    );

    Future<List<Size>> covers(WidgetTester tester, MusicShelf shelf) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      await pumpApp(tester);
      // A card looks up the count of its song in the app's memory of what lists showed
      final model = AppScope.of(tester.element(find.byType(MaterialApp).first));
      await tester.pumpWidget(
        AppScope(
          model: model,
          child: MaterialApp(
            theme: buildTheme(Palette.dark),
            home: Scaffold(body: MusicShelfView(shelf: shelf)),
          ),
        ),
      );
      return [
        for (final e in find.byType(Artwork).evaluate())
          tester.getSize(find.byWidget(e.widget)),
      ];
    }

    testWidgets('has wide covers, 16:9, that keep the lettering at the edges', (
      tester,
    ) async {
      final sizes = await covers(
        tester,
        MusicShelf(
          title: 'Videos',
          tracks: [
            track('aaaaaaaaaaa', song: false),
            track('bbbbbbbbbbb', song: false),
          ],
        ),
      );
      expect(sizes, isNotEmpty);
      for (final size in sizes) {
        expect(size.width / size.height, closeTo(16 / 9, 0.01));
      }
    });

    testWidgets('of songs keeps square covers', (tester) async {
      final sizes = await covers(
        tester,
        MusicShelf(
          title: 'Songs',
          tracks: [
            track('aaaaaaaaaaa', song: true),
            track('bbbbbbbbbbb', song: false),
          ],
        ),
      );
      for (final size in sizes) {
        expect(size.width, size.height);
      }
    });
  });

  group('the sleep timer', () {
    testWidgets('takes any number of minutes', (tester) async {
      final backend = await _openPlayer(tester);
      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Another time…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '25');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        backend.calls.any((c) => c.startsWith('sleep') && c.contains('25')),
        isTrue,
        reason: '${backend.calls}',
      );
    });

    testWidgets('does not take what is not minutes', (tester) async {
      final backend = await _openPlayer(tester);
      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Another time…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('sleep')), isEmpty);
    });
  });
}
