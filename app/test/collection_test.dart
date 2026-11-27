import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/ui/artist_page.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/player/up_next_view.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';

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
    testWidgets('on a phone on its side the cover is beside the songs', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      tester.view.physicalSize = const Size(1688, 780);
      await tester.pump();
      backend.collectionResult = album;
      await openAlbum(tester, context);
      expect(tester.takeException(), isNull);
      final cover = tester.getRect(find.byType(CollectionCover));
      final one = tester.getRect(find.text('One'));
      expect(cover.right, lessThan(one.left));
      expect(cover.height, lessThan(200));
      expect(tester.getRect(find.text('The Album')).right, lessThan(one.left));
    });

    testWidgets('has the streams of its first songs looked up while it opens', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      expect(backend.warmed, ['a1aaaaaaaaa,a2aaaaaaaaa,a3aaaaaaaaa']);
    });

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
          'playList a1aaaaaaaaa,a2aaaaaaaaa,a3aaaaaaaaa start=0 label=The Album',
        ]),
      );
    });

    testWidgets('Shuffle plays all of it too, in some order', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.byTooltip('Shuffle'));
      await tester.pumpAndSettle();
      final added = backend.calls.firstWhere((c) => c.startsWith('playList'));
      final ids = added.split(' ')[1].split(',')..sort();
      expect(ids, ['a1aaaaaaaaa', 'a2aaaaaaaaa', 'a3aaaaaaaaa']);
    });

    testWidgets('a touch on a song plays the whole album from it', (tester) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = album;
      await openAlbum(tester, context);
      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(
        backend.calls,
        containsAllInOrder([
          'playList a1aaaaaaaaa,a2aaaaaaaaa,a3aaaaaaaaa start=1 label=The Album',
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
          'playList p1aaaaaaaaa,p2aaaaaaaaa,p3aaaaaaaaa,p4aaaaaaaaa start=0 label=Long Mix',
        ]),
      );
    });

    void queueIs(FakeBackend backend, List<String> ids) =>
        backend.afterPlayList = (_) => backend.emit(
          StateEvent(
            sampleRoom(
              local: true,
              queue: [
                for (final id in ids)
                  QueueEntry(id: 'q$id', videoId: id, title: id, artist: 'x', durMs: 1, addedBy: ''),
              ],
            ),
          ),
        );

    testWidgets('a touch on a song plays the page from it, and the pages after it join the queue', (
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
      queueIs(backend, ['p1aaaaaaaaa', 'p2aaaaaaaaa']);
      await openAlbum(tester, context, id: 'PLlong');
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('playList p1aaaaaaaaa,p2aaaaaaaaa start=1 label=Long Mix'));
      expect(backend.calls, contains('addMany p3aaaaaaaaa,p4aaaaaaaaa next=false queued=false'));
    });

    testWidgets('the pages after it are left out when the queue became something else meanwhile', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = playlist;
      backend.moreResults['TOKEN1'] = MoreTracks(tracks: [music('p3aaaaaaaaa', 'Third')]);
      queueIs(backend, ['other000000']);
      await openAlbum(tester, context, id: 'PLlong');
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('playList p1aaaaaaaaa,p2aaaaaaaaa start=1 label=Long Mix'));
      expect(backend.calls.where((c) => c.startsWith('addMany')), isEmpty);
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

    testWidgets('the episodes of a podcast take the name of the show', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      backend.collectionResult = CollectionPage(
        id: 'MPSPshow',
        title: 'The Show',
        tracks: [music('e0aaaaaaaaa', 'Episode 0', artist: 'The Show')],
        more: 'TOKEN1',
      );
      // The rows after the first ones do not say which show they are of
      backend.moreResults['TOKEN1'] = MoreTracks(
        tracks: [music('e1aaaaaaaaa', 'Episode 1', artist: '')],
      );
      await openAlbum(tester, context, id: 'MPSPshow');
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('musicMore TOKEN1'));
      expect(backend.lastAddedMany.map((t) => t.artist), [
        'The Show',
        'The Show',
      ]);
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

    testWidgets('a hyphen in the name is not a place to break the line', (tester) async {
      final (backend, context) = await start(tester);
      backend.artistResult = const ArtistPage(id: 'UCmtp', name: 'Sơn Tùng M-TP', subscribers: '9M');
      openArtist(context, 'UCmtp');
      await tester.pumpAndSettle();
      expect(find.text('Sơn Tùng M\u2011TP'), findsOneWidget);
      expect(find.text('Sơn Tùng M-TP'), findsNothing);
    });

    testWidgets('has play and shuffle, top songs, releases and more', (
      tester,
    ) async {
      await open(tester);
      // The colours come from the picture, as on the page of an album
      expect(find.byType(PlayerBackdrop), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
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
          'playList t1aaaaaaaaa,t2aaaaaaaaa start=0 label=Zen · Top songs',
        ]),
      );
    });

    testWidgets('a touch on a top song plays the list of them from it', (tester) async {
      final (backend, _) = await open(tester);
      await tester.tap(find.text('Hit'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('playList t1aaaaaaaaa start=0 label=Zen · Top songs'));
      expect(backend.calls.any((c) => c.startsWith('radio')), isFalse);
    });

    testWidgets('See all opens the playlist of the top songs', (tester) async {
      await open(tester);
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(find.text('Next Hit'), findsOneWidget);
    });

    testWidgets(
      'in a wide window the picture and what is said stay beside the songs',
      (tester) async {
        final (backend, context) = await start(tester);
        tester.view.physicalSize = const Size(2560, 1600);
        await tester.pump();
        backend.artistResult = page;
        openArtist(context, 'UCzen');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final play = tester.getRect(find.byTooltip('Play'));
        final hit = tester.getRect(find.text('Hit'));
        // Beside each other, not one under the other: the buttons end where the songs have not begun
        expect(play.right, lessThan(hit.left));
        expect(
          tester.getRect(find.text('1.2M subscribers')).right,
          lessThan(hit.left),
        );
        // The artist's own words are on the left too, without scrolling to them
        expect(find.text('About the artist'), findsOneWidget);
        expect(
          tester.getRect(find.text('About the artist')).right,
          lessThan(hit.left),
        );
        // The releases are on the right, under the songs
        await tester.scrollUntilVisible(
          find.text('Debut'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        expect(
          tester.getRect(find.text('Debut')).left,
          greaterThan(play.right),
        );
      },
    );

    testWidgets('a phone on its side has them beside the songs too', (
      tester,
    ) async {
      final (backend, context) = await start(tester);
      tester.view.physicalSize = const Size(1688, 780);
      await tester.pump();
      backend.artistResult = page;
      openArtist(context, 'UCzen');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final hit = tester.getRect(find.text('Hit'));
      expect(tester.getRect(find.byTooltip('Play')).right, lessThan(hit.left));
      // The picture is small enough to leave room for what is under it
      expect(tester.getSize(find.byType(ClipRRect).first).height, lessThan(200));
    });

    testWidgets('on a phone on its side the name stands beside the small picture, not on it', (tester) async {
      final (backend, context) = await start(tester);
      tester.view.physicalSize = const Size(1688, 780);
      await tester.pump();
      backend.artistResult = page;
      openArtist(context, 'UCzen');
      await tester.pumpAndSettle();
      final picture = tester.getRect(find.byType(ClipRRect).first);
      expect(tester.getRect(find.text(page.name).first).left, greaterThanOrEqualTo(picture.right));
      expect(tester.getRect(find.text('1.2M subscribers')).left, greaterThanOrEqualTo(picture.right));
    });

    testWidgets('in a wide window "See all" is over the "…" of the songs, not at the far edge of the page', (tester) async {
      final (backend, context) = await start(tester);
      tester.view.physicalSize = const Size(2560, 1600);
      await tester.pump();
      backend.artistResult = page;
      openArtist(context, 'UCzen');
      await tester.pumpAndSettle();
      final seeAll = tester.getRect(find.text('See all'));
      final menu = tester.getRect(find.byIcon(Icons.more_horiz_rounded).first);
      expect(seeAll.right, closeTo(menu.right, 16));
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

  group('the two-group Up Next view', () {
    RoomSnapshot twoGroupQueue({bool inRoom = false, String? label = 'Lofi Chill'}) => RoomSnapshot(
      room: inRoom ? 'ABC234' : null,
      link: Link.connected,
      you: 'me',
      phase: 'playing',
      index: 0,
      label: inRoom ? null : label,
      queue: [
        const QueueEntry(
          id: 'cur',
          videoId: 'curaaaaaaaa',
          title: 'Current Song',
          artist: 'Zen',
          durMs: 200000,
          addedBy: 'me',
        ),
        QueueEntry(
          id: 'q1',
          videoId: 'q1aaaaaaaaa',
          title: 'Queued One',
          artist: 'Zen',
          durMs: 200000,
          addedBy: 'me',
          queued: !inRoom,
        ),
        QueueEntry(
          id: 'q2',
          videoId: 'q2aaaaaaaaa',
          title: 'Queued Two',
          artist: 'Zen',
          durMs: 200000,
          addedBy: 'me',
          queued: !inRoom,
        ),
        const QueueEntry(
          id: 'c1',
          videoId: 'c1aaaaaaaaa',
          title: 'List Song One',
          artist: 'Zen',
          durMs: 200000,
          addedBy: 'me',
        ),
        const QueueEntry(
          id: 'c2',
          videoId: 'c2aaaaaaaaa',
          title: 'List Song Two',
          artist: 'Zen',
          durMs: 200000,
          addedBy: 'me',
        ),
      ],
    );

    testWidgets('shows Next in queue with Clear and Next from with the list name, and Clear offers Undo', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, listen: true);
      backend.emit(StateEvent(twoGroupQueue()));
      await tester.pumpAndSettle();

      await tapMiniPlayer(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Up next'));
      await tester.pumpAndSettle();

      expect(find.byType(UpNextView), findsOneWidget);
      expect(find.text('Next in queue'), findsOneWidget);
      expect(find.text('Next from: Lofi Chill'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(tester.getSize(find.widgetWithText(TextButton, 'Clear')).height, greaterThanOrEqualTo(48));

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(backend.calls.last, 'clearQueued');
      expect(find.text('Queue cleared'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      // Native reports the queued songs cleared, then Undo puts them back
      backend.emit(
        StateEvent(
          RoomSnapshot(
            phase: 'playing',
            index: 0,
            label: 'Lofi Chill',
            queue: [
              for (final e in twoGroupQueue().queue)
                if (!e.queued) e,
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(backend.calls.last, 'addMany q1aaaaaaaaa,q2aaaaaaaaa next=false');
    });

    testWidgets('dragging between the two groups tells the native side which group the song was dropped into', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, listen: true);
      backend.emit(StateEvent(twoGroupQueue()));
      await tester.pumpAndSettle();

      await tapMiniPlayer(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Up next'));
      await tester.pumpAndSettle();

      final list = tester.widget<SliverReorderableList>(find.byType(SliverReorderableList));
      // Items in the list: 0=q1, 1=q2, 2=heading("Next from: Lofi Chill"), 3=c1, 4=c2
      // Drag c1 (index 3) above the heading into the queued group at slot 1
      list.onReorderItem!(3, 1);
      await tester.pump();
      expect(backend.calls.last, 'move c1 2 queued=true');

      // Drag q1 (index 0) below the heading into the context list at slot 3
      list.onReorderItem!(0, 3);
      await tester.pump();
      expect(backend.calls.last, 'move q1 3 queued=false');
    });

    testWidgets('in a room the queue stays one flat Up next list without Clear', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, listen: true);
      backend.emit(StateEvent(twoGroupQueue(inRoom: true)));
      await tester.pumpAndSettle();

      await tapMiniPlayer(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Up next'));
      await tester.pumpAndSettle();

      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('Next in queue'), findsNothing);
      expect(find.text('Clear'), findsNothing);

      final list = tester.widget<SliverReorderableList>(find.byType(SliverReorderableList));
      list.onReorderItem!(1, 0);
      await tester.pump();
      expect(backend.calls.last, 'move q2 1');
    });
  });
}
