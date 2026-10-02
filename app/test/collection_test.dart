import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/music_models.dart';
import 'package:unison/ui/artist_page.dart';
import 'package:unison/ui/collection_screen.dart';
import 'package:unison/ui/home_shell.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

MusicTrack music(String id, String title, {String artist = 'Zen'}) =>
    MusicTrack(
      videoId: id,
      title: title,
      artist: artist,
      durMs: 200000,
      isSong: true,
    );

/// Starts on the home page, with a way to open a page on top of it.
Future<(FakeBackend, BuildContext)> start(
  WidgetTester tester, {
  bool inRoom = false,
}) async {
  final (backend, _) = await pumpApp(tester, listen: false);
  backend.emit(
    StateEvent(
      inRoom ? sampleRoom(songs: 0, phase: 'idle') : const RoomSnapshot(),
    ),
  );
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  return (backend, tester.element(find.byType(HomeShell)));
}

Future<void> openAlbum(
  WidgetTester tester,
  BuildContext context, {
  String id = 'MPREb_album',
}) async {
  openCollection(context, id: id, title: 'Placeholder');
  await tester.pumpAndSettle();
}

void main() {
  final album = CollectionPage(
    id: 'MPREb_album',
    title: 'The Album',
    kind: 'Album',
    year: '2017',
    owner: 'Zen',
    ownerId: 'UCzen',
    description: 'Made in a hurry.',
    stats: const ['3 songs', '10 minutes'],
    tracks: [
      MusicTrack(
        videoId: 'a1aaaaaaaaa',
        title: 'One',
        artist: 'Zen',
        durMs: 200000,
        stats: '9M plays',
      ),
      MusicTrack(
        videoId: 'a2aaaaaaaaa',
        title: 'Two',
        artist: 'Zen & Friend',
        durMs: 200000,
      ),
      MusicTrack(
        videoId: 'a3aaaaaaaaa',
        title: 'Three',
        artist: 'Zen',
        durMs: 200000,
      ),
    ],
    shelves: const [
      MusicShelf(
        title: 'More by Zen',
        albums: [Release(id: 'MPREb_other', title: 'Other Album')],
      ),
    ],
  );

  group('an album', () {
    testWidgets('has its cover facts, numbered songs and rows below', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      expect(backend.calls, contains('musicCollection MPREb_album'));
      expect(find.text('The Album'), findsOneWidget);
      expect(find.text('Album · 2017'), findsOneWidget);
      expect(find.text('Zen'), findsOneWidget, reason: 'the artist, once');
      expect(find.text('Made in a hurry.'), findsOneWidget);
      // Numbered, and the artist only said where it is another one
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('9M plays'), findsOneWidget);
      expect(find.text('Zen & Friend'), findsOneWidget);
      expect(find.text('3 songs · 10 minutes'), findsOneWidget);
      expect(find.text('More by Zen'), findsOneWidget);
      expect(find.text('Other Album'), findsOneWidget);
    });

    testWidgets('opens the artist from its name', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Zen'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicArtist UCzen'));
    });

    testWidgets('another album in a row opens', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Other Album'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicCollection MPREb_other'));
    });

    testWidgets('Play replaces the queue with all of it, in order', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        containsAllInOrder([
          'clear',
          'addMany a1aaaaaaaaa,a2aaaaaaaaa,a3aaaaaaaaa next=false',
        ]),
      );
    });

    testWidgets('Shuffle plays all of it too, in some order', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.byTooltip('Shuffle'));
      await tester.pumpAndSettle();
      final added = backend.calls.firstWhere((c) => c.startsWith('addMany'));
      final ids = added.split(' ')[1].split(',')..sort();
      expect(ids, ['a1aaaaaaaaa', 'a2aaaaaaaaa', 'a3aaaaaaaaa']);
      expect(backend.calls, contains('clear'));
    });

    testWidgets('a touch on a song plays on from it', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(
        backend.calls,
        containsAllInOrder([
          'clear',
          'addMany a2aaaaaaaaa,a3aaaaaaaaa next=false',
        ]),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('in a room Play only adds, and says so', (tester) async {
      final (backend, context) = await start(tester, inRoom: true);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('clear')));
      expect(backend.calls.any((c) => c.startsWith('addMany a1')), isTrue);
      expect(find.text('Playlist added'), findsOneWidget);
    });

    testWidgets('the menu puts it next in the queue', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        contains('addMany a1aaaaaaaaa,a2aaaaaaaaa,a3aaaaaaaaa next=true'),
      );
    });
  });

  group('a playlist', () {
    final playlist = CollectionPage(
      id: 'PLlong',
      title: 'Long Mix',
      kind: 'Playlist',
      owner: 'Anna',
      tracks: [music('p1aaaaaaaaa', 'First'), music('p2aaaaaaaaa', 'Second')],
      more: 'TOKEN1',
    );

    testWidgets('shows covers instead of numbers and who made it', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = playlist;
      await openAlbum(tester, context, id: 'PLlong');
      expect(find.text('Playlist'), findsOneWidget);
      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('1'), findsNothing);
      // Without a page of its own the name of the maker is not a link
      await tester.tap(find.text('Anna'));
      await tester.pumpAndSettle();
      expect(backend.calls.any((c) => c.startsWith('musicArtist')), isFalse);
    });

    testWidgets('Play asks for the rest of a long playlist first', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = playlist;
      backend.moreResults['TOKEN1'] = MoreTracks(
        tracks: [music('p3aaaaaaaaa', 'Third')],
        more: 'TOKEN2',
      );
      backend.moreResults['TOKEN2'] = MoreTracks(
        tracks: [music('p4aaaaaaaaa', 'Fourth')],
      );
      await openAlbum(tester, context, id: 'PLlong');
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        containsAllInOrder([
          'musicMore TOKEN1',
          'musicMore TOKEN2',
          'clear',
          'addMany p1aaaaaaaaa,p2aaaaaaaaa,p3aaaaaaaaa,p4aaaaaaaaa next=false',
        ]),
      );
    });

    testWidgets('the next songs are asked for as the end comes near', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = CollectionPage(
        id: 'PLlong',
        title: 'Long Mix',
        kind: 'Playlist',
        tracks: [for (var i = 0; i < 12; i++) music('s${i}aaaaaaaaaa', 'S$i')],
        more: 'TOKEN1',
      );
      backend.moreResults['TOKEN1'] = MoreTracks(
        tracks: [music('tailaaaaaaa', 'Tail')],
      );
      await openAlbum(tester, context, id: 'PLlong');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicMore TOKEN1'));
      expect(find.text('Tail'), findsOneWidget);
    });

    testWidgets('a page that cannot be opened can be tried again', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.musicFailWith = Exception('offline');
      await openAlbum(tester, context, id: 'PLlong');
      expect(find.text('Try again'), findsOneWidget);
      backend.musicFailWith = null;
      backend.collectionResult = playlist;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Long Mix'), findsOneWidget);
    });

    testWidgets('shows what it is called while it loads', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = playlist;
      backend.musicGate = Completer<void>();
      openCollection(context, id: 'PLlong', title: 'Long Mix');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Long Mix'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      backend.musicGate!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('an artist', () {
    final page = ArtistPage(
      id: 'UCzen',
      name: 'Zen',
      subscribers: '1.2M',
      description: 'Plays quietly.',
      topSongs: [music('t1aaaaaaaaa', 'Hit')],
      topSongsId: 'OLAKtop',
      albums: const [Release(id: 'MPREb_a', title: 'Debut')],
      singles: const [Release(id: 'MPREb_s', title: 'A Single')],
      shelves: [
        MusicShelf(title: 'Videos', tracks: [music('v1aaaaaaaaa', 'Clip')]),
        const MusicShelf(
          title: 'Featured on',
          playlists: [Release(id: 'PLfeat', title: 'Calm Mix')],
        ),
      ],
      similar: const [ArtistCard(id: 'UCother', name: 'Other One')],
    );

    Future<(FakeBackend, BuildContext)> open(WidgetTester tester) async {
      final (backend, context) = await start(tester);
      backend.artistResult = page;
      backend.collectionResult = CollectionPage(
        id: 'OLAKtop',
        title: 'Top songs',
        tracks: [music('t1aaaaaaaaa', 'Hit'), music('t2aaaaaaaaa', 'Next Hit')],
      );
      openArtist(context, 'UCzen');
      await tester.pumpAndSettle();
      return (backend, context);
    }

    testWidgets('has play and shuffle, top songs, releases and more', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('1.2M subscribers'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsOneWidget);
      expect(find.text('Top songs'), findsOneWidget);
      expect(find.text('Hit'), findsOneWidget);
      expect(find.text('See all'), findsOneWidget);
      // The page is long, so what is far down is only there once it is scrolled to
      for (final text in [
        'Albums',
        'Debut',
        'Singles & EPs',
        'Videos',
        'Clip',
        'Featured on',
        'Fans might also like',
        'Other One',
        'About the artist',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(text), findsOneWidget);
      }
    });

    testWidgets('Play takes all of the top songs, not only those shown', (
      tester,
    ) async {
      final (backend, _) = await open(tester);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicCollection OLAKtop'));
      expect(
        backend.calls,
        containsAllInOrder([
          'clear',
          'addMany t1aaaaaaaaa,t2aaaaaaaaa next=false',
        ]),
      );
    });

    testWidgets('See all opens the playlist of the top songs', (tester) async {
      await open(tester);
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(find.text('Next Hit'), findsOneWidget);
    });

    testWidgets('a profile has no play and shuffle without songs', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.artistResult = ArtistPage(
        id: 'UCme',
        name: 'Somebody',
        shelves: [
          MusicShelf(title: 'Videos', tracks: [music('v1aaaaaaaaa', 'Clip')]),
        ],
      );
      openArtist(context, 'UCme');
      await tester.pumpAndSettle();
      expect(find.text('Somebody'), findsOneWidget);
      expect(find.text('Clip'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
      expect(find.byTooltip('Shuffle'), findsNothing);
    });
  });
}
