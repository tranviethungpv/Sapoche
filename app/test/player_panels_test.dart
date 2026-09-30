import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/music_models.dart';
import 'package:unison/ui/widgets/mini_player.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// Opens the full player on the first of three songs.
Future<FakeBackend> openPlayer(
  WidgetTester tester, {
  RoomSnapshot? snapshot,
}) async {
  final (backend, _) = await pumpApp(tester);
  backend.emit(StateEvent(snapshot ?? sampleRoom()));
  backend.emit(
    const PositionEvent(
      PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.byType(MiniPlayer));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  return backend;
}

Future<void> openPanel(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

const song = MusicTrack(
  videoId: 'video0',
  title: 'Song 0',
  artist: 'Artist 0',
  durMs: 200000,
  artistId: 'UC1',
  album: 'The Album',
  year: '1987',
  isSong: true,
);

void main() {
  group('lyrics', () {
    testWidgets('run along with the song, and a touch on a line jumps there', (
      tester,
    ) async {
      final backend = await openPlayer(tester);
      backend.lyricsResult = const Lyrics(
        lines: [LyricLine(0, 'First line'), LyricLine(5000, 'Second line')],
      );
      await openPanel(tester, 'Lyrics');

      expect(backend.calls, contains('lyrics video0'));
      expect(find.text('First line'), findsOneWidget);
      expect(find.text('Second line'), findsOneWidget);

      await tester.tap(find.text('Second line'));
      await tester.pump();
      expect(backend.calls.last, 'seek 5000');
      await tester.pump(const Duration(seconds: 2)); // the seek settles
    });

    testWidgets('without times are shown as they are', (tester) async {
      final backend = await openPlayer(tester);
      backend.lyricsResult = const Lyrics(plain: 'Only the words');
      await openPanel(tester, 'Lyrics');
      expect(find.text('Only the words'), findsOneWidget);
    });

    testWidgets('that nobody wrote down say so', (tester) async {
      await openPlayer(tester);
      await openPanel(tester, 'Lyrics');
      expect(find.text('No lyrics for this song'), findsOneWidget);
    });

    testWidgets('that could not be fetched can be asked for again', (
      tester,
    ) async {
      final backend = await openPlayer(tester);
      backend.failWith = StateError('offline');
      await openPanel(tester, 'Lyrics');
      expect(find.text('Couldn’t load the lyrics'), findsOneWidget);

      backend.failWith = null;
      backend.lyricsResult = const Lyrics(plain: 'Back online');
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Back online'), findsOneWidget);
    });

    testWidgets('are asked for once however often the panel is opened', (
      tester,
    ) async {
      final backend = await openPlayer(tester);
      backend.lyricsResult = const Lyrics(plain: 'Words');
      await openPanel(tester, 'Lyrics');
      await openPanel(tester, 'Lyrics'); // back to the cover
      await openPanel(tester, 'Lyrics');
      expect(backend.calls.where((c) => c == 'lyrics video0'), hasLength(1));
    });

    testWidgets('close again with the same button', (tester) async {
      await openPlayer(tester);
      expect(find.byTooltip('Repeat off'), findsOneWidget);
      await openPanel(tester, 'Lyrics');
      expect(find.byTooltip('Repeat off'), findsNothing);
      await openPanel(tester, 'Lyrics');
      expect(find.byTooltip('Repeat off'), findsOneWidget);
    });
  });

  group('up next', () {
    testWidgets(
      'lists what comes next and suggests songs that are not queued',
      (tester) async {
        final backend = await openPlayer(tester);
        backend.radioResult = const SongRadio(
          tracks: [
            song,
            MusicTrack(
              videoId: 'freshaaaaaa',
              title: 'Fresh A',
              artist: 'New',
              durMs: 100000,
            ),
            // Song 1 is in the queue already
            MusicTrack(
              videoId: 'video1',
              title: 'Song 1',
              artist: 'Artist 1',
              durMs: 100000,
            ),
          ],
        );
        await openPanel(tester, 'Up Next');

        expect(backend.calls, contains('musicNext video0'));
        expect(
          find.text('Song 1'),
          findsOneWidget,
          reason: 'only in the queue',
        );
        expect(find.text('Song 2'), findsOneWidget);
        expect(find.text('Suggested'), findsOneWidget, reason: 'in a room');
        expect(find.text('Fresh A'), findsOneWidget);

        await tester.tap(find.text('Fresh A'));
        await tester.pump();
        expect(backend.calls.last, 'add freshaaaaaa next=false');
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets(
      'outside a room the suggestions are the autoplay, with a switch',
      (tester) async {
        final backend = await openPlayer(
          tester,
          snapshot: RoomSnapshot(
            phase: 'paused',
            queue: const [
              QueueEntry(
                id: 'q0',
                videoId: 'video0',
                title: 'Song 0',
                artist: 'Artist 0',
                durMs: 200000,
                addedBy: '',
              ),
            ],
          ),
        );
        backend.radioResult = const SongRadio(tracks: [song]);
        await openPanel(tester, 'Up Next');

        expect(find.text('Autoplay'), findsOneWidget);
        expect(find.text('Nothing is queued after this song.'), findsOneWidget);
        await tester.tap(find.byType(Switch));
        await tester.pump();
        expect(backend.calls.last, 'autoplay false');
      },
    );

    testWidgets('say so when YouTube Music cannot be reached', (tester) async {
      final backend = await openPlayer(tester);
      backend.failWith = StateError('offline');
      await openPanel(tester, 'Up Next');
      expect(find.text('Couldn’t reach YouTube Music'), findsOneWidget);
    });
  });

  group('related', () {
    testWidgets('shows songs, other performances and artists to open', (
      tester,
    ) async {
      final backend = await openPlayer(tester);
      backend.relatedResult = const RelatedPage(
        more: [
          MusicTrack(
            videoId: 'relatedaaaa',
            title: 'Related A',
            artist: 'x',
            durMs: 1000,
          ),
        ],
        otherPerformances: [
          MusicTrack(
            videoId: 'coveraaaaaa',
            title: 'A Cover',
            artist: 'y',
            durMs: 1000,
          ),
        ],
        artists: [ArtistCard(id: 'UC9', name: 'Some Band')],
        about: 'Text about the artist',
      );
      await openPanel(tester, 'Related');

      expect(find.text('You might also like'), findsOneWidget);
      expect(find.text('Related A'), findsOneWidget);
      expect(find.text('Other performances'), findsOneWidget);
      expect(find.text('A Cover'), findsOneWidget);
      expect(find.text('Similar artists'), findsOneWidget);
      expect(find.text('Text about the artist'), findsOneWidget);

      await tester.tap(find.text('Related A'));
      await tester.pump();
      expect(backend.calls.last, 'add relatedaaaa next=false');
      await tester.pump(const Duration(seconds: 2));

      backend.artistResult = const ArtistPage(id: 'UC9', name: 'Some Band');
      await tester.tap(find.text('Some Band'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicArtist UC9'));
      expect(find.text('Some Band'), findsOneWidget);
    });

    testWidgets('say when there is nothing related', (tester) async {
      await openPlayer(tester);
      await openPanel(tester, 'Related');
      expect(
        find.text('Nothing related to this song was found'),
        findsOneWidget,
      );
    });
  });

  group('song and artist', () {
    Future<void> openMenu(WidgetTester tester, String item) async {
      await tester.tap(
        find.descendant(
          of: find.byType(Scaffold).last,
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('the info sheet tells the album, year and length', (
      tester,
    ) async {
      final backend = await openPlayer(tester);
      backend.radioResult = const SongRadio(tracks: [song]);
      await openMenu(tester, 'Song info');

      expect(find.text('The Album'), findsOneWidget);
      expect(find.text('1987'), findsOneWidget);
      expect(find.text('Song'), findsOneWidget);
      expect(find.text('3:20'), findsOneWidget);
      expect(find.text('You'), findsOneWidget, reason: 'who added it');
    });

    testWidgets('the artist is opened from the sheet', (tester) async {
      final backend = await openPlayer(tester);
      backend.radioResult = const SongRadio(tracks: [song]);
      backend.artistResult = const ArtistPage(
        id: 'UC1',
        name: 'Artist 0',
        description: 'Bio text',
        subscribers: '4.55M subscribers',
        topSongs: [
          MusicTrack(
            videoId: 'topaaaaaaaa',
            title: 'Top Song',
            artist: 'Artist 0',
            durMs: 1000,
          ),
        ],
        similar: [ArtistCard(id: 'UC2', name: 'Fan Favourite')],
      );
      await openMenu(tester, 'Song info');
      await tester.tap(find.text('Artist'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('musicArtist UC1'));
      expect(find.text('4.55M subscribers'), findsOneWidget);
      expect(find.text('Top Song'), findsOneWidget);
      expect(find.text('Bio text'), findsOneWidget);
      expect(find.text('Fan Favourite'), findsOneWidget);
    });

    testWidgets('the artist is opened from the menu', (tester) async {
      final backend = await openPlayer(tester);
      backend.radioResult = const SongRadio(tracks: [song]);
      await openMenu(tester, 'Go to artist');
      expect(backend.calls, contains('musicArtist UC1'));
    });

    testWidgets('a song with no known artist says so instead of opening one', (
      tester,
    ) async {
      await openPlayer(tester);
      await openMenu(tester, 'Go to artist');
      expect(find.text('Couldn’t reach YouTube Music'), findsOneWidget);
    });
  });
}
