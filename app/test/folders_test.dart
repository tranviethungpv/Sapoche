import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/library_controller.dart';
import 'package:sapoche/data/models.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

Track _song(String list, int i) => Track(
  videoId: '$list${i.toString().padLeft(10, '0')}'.substring(0, 11),
  title: 'Song $list$i',
  artist: 'Artist $list',
  durMs: 1000,
);

List<Track> _songs(String list, int n) => [
  for (var i = 0; i < n; i++) _song(list, i),
];

void main() {
  group('the controller', () {
    late FakeBackend backend;
    late LibraryController library;

    setUp(() {
      backend = FakeBackend();
      library = LibraryController(backend, quiet: Duration.zero);
    });

    tearDown(() => library.dispose());

    test('lists folders apart from the playlists that are in none', () async {
      await library.start();
      final trip = (await library.createPlaylist('Trip', _songs('t', 2)))!;
      final gym = (await library.createPlaylist('Gym', _songs('g', 3)))!;
      final mixes = (await library.createFolder('Mixes'))!;
      expect(library.loosePlaylists.map((p) => p.name), ['Gym', 'Trip']);

      await library.moveToFolder(trip, mixes);
      expect(library.folders.single.name, 'Mixes');
      expect(library.playlistsIn(mixes).map((p) => p.id), [trip]);
      expect(library.loosePlaylists.map((p) => p.id), [gym]);
      expect(backend.calls, contains('setPlaylistFolder $trip $mixes'));
    });

    test('deleting a folder frees its playlists', () async {
      await library.start();
      final trip = (await library.createPlaylist('Trip'))!;
      final mixes = (await library.createFolder('Mixes'))!;
      await library.moveToFolder(trip, mixes);
      await library.deleteFolder(mixes);
      expect(library.folders, isEmpty);
      expect(library.loosePlaylists.map((p) => p.id), [trip]);
    });

    test('the songs of playlists come in the order asked', () async {
      await library.start();
      final a = (await library.createPlaylist('A', _songs('a', 2)))!;
      final b = (await library.createPlaylist('B', _songs('b', 1)))!;
      final lists = await library.songsOfPlaylists([b, a]);
      expect(lists.map((l) => l.length), [1, 2]);
      expect(lists.first.single.title, 'Song b0');
    });

    test(
      'a playlist that points to a folder that is gone is still listed',
      () async {
        await library.start();
        final trip = (await library.createPlaylist('Trip'))!;
        backend.playlistFolders[trip] = 99;
        await library.refresh();
        expect(library.loosePlaylists.map((p) => p.id), [trip]);
      },
    );
  });

  group('the page of a folder', () {
    late FakeBackend backend;

    /// A folder "Mixes" with Trip (2 songs) and Gym (3), a playlist "Alone" outside it, and the library open.
    Future<void> open(WidgetTester tester, {int trip = 2, int gym = 3}) async {
      final (b, _) = await pumpApp(tester);
      backend = b;
      final folder = await b.createFolder('Mixes');
      final t = await b.createPlaylist('Trip', _songs('t', trip));
      final g = await b.createPlaylist('Gym', _songs('g', gym));
      await b.createPlaylist('Alone', _songs('a', 1));
      await b.setPlaylistFolder(t, folder);
      await b.setPlaylistFolder(g, folder);
      b.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      b.emit(const LibraryEvent());
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the library lists the folder with what is in it, and not the playlists inside',
      (tester) async {
        await open(tester);
        expect(find.text('Mixes'), findsOneWidget);
        expect(find.text('2 playlists · 5 songs'), findsOneWidget);
        expect(find.text('Alone'), findsOneWidget);
        expect(find.text('Trip'), findsNothing);
        expect(find.text('Gym'), findsNothing);
      },
    );

    testWidgets('opening it lists its playlists', (tester) async {
      await open(tester);
      await tester.tap(find.text('Mixes'));
      await tester.pumpAndSettle();
      expect(find.text('Trip'), findsOneWidget);
      expect(find.text('Gym'), findsOneWidget);
      expect(find.text('Alone'), findsNothing);
    });

    testWidgets(
      'Play puts the playlists one after the other in the place of the queue',
      (tester) async {
        await open(tester);
        await tester.tap(find.text('Mixes'));
        await tester.pumpAndSettle();
        backend.calls.clear();
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();
        final sent = backend.calls
            .where((c) => c == 'clear' || c.startsWith('addMany'))
            .toList();
        expect(sent.first, 'clear');
        // Gym was changed after Trip, so it is listed first and plays first
        final ids = sent.last.split(' ')[1].split(',');
        expect(ids.length, 5);
        expect(ids.take(3).every((id) => id.startsWith('g')), isTrue);
        expect(ids.skip(3).every((id) => id.startsWith('t')), isTrue);
      },
    );

    testWidgets('Shuffle mixes the songs of every playlist together', (
      tester,
    ) async {
      await open(tester, trip: 30, gym: 30);
      await tester.tap(find.text('Mixes'));
      await tester.pumpAndSettle();
      backend.calls.clear();
      await tester.tap(find.byTooltip('Shuffle'));
      await tester.pumpAndSettle();
      final ids = backend.calls
          .firstWhere((c) => c.startsWith('addMany'))
          .split(' ')[1]
          .split(',');
      expect(ids.length, 60);
      expect(ids.toSet().length, 60);
      expect(
        ids.sublist(0, 6).map((id) => id[0]).toSet(),
        hasLength(2),
        reason: 'both playlists are heard from the start',
      );
    });

    testWidgets('more than a queue holds is cut and said', (tester) async {
      await open(tester, trip: 500, gym: 500);
      // A third playlist in the folder makes 1,200 songs
      final more = await backend.createPlaylist('More', _songs('m', 200));
      await backend.setPlaylistFolder(more, 1);
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mixes'));
      await tester.pumpAndSettle();
      backend.calls.clear();
      await tester.tap(find.byTooltip('Shuffle'));
      await tester.pumpAndSettle();
      final ids = backend.calls
          .firstWhere((c) => c.startsWith('addMany'))
          .split(' ')[1]
          .split(',');
      expect(ids.length, 1000);
      expect(
        find.text('Playing 1000 of 1200 songs, as many as a queue holds'),
        findsOneWidget,
      );
      // Every playlist keeps its share of what was cut: about 417, 417 and 167 of the 1,200
      expect(
        ids.where((id) => id.startsWith('m')).length,
        inInclusiveRange(150, 185),
      );
    });

    testWidgets(
      'a folder with nothing in it asks for playlists, and they go in from a sheet',
      (tester) async {
        final (b, _) = await pumpApp(tester);
        final folder = await b.createFolder('Empty one');
        final trip = await b.createPlaylist('Trip', _songs('t', 2));
        b.emit(const StateEvent(RoomSnapshot()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Library'));
        await tester.pumpAndSettle();
        b.emit(const LibraryEvent());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empty one'));
        await tester.pumpAndSettle();
        expect(find.text('This folder is empty'), findsOneWidget);

        await tester.tap(find.text('Add playlists'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Trip'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(b.calls, contains('setPlaylistFolder $trip $folder'));
        expect(find.text('This folder is empty'), findsNothing);
        expect(find.text('Trip'), findsOneWidget);
      },
    );

    testWidgets('a playlist leaves the folder from the menu of its row', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Mixes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from folder'));
      await tester.pumpAndSettle();
      expect(
        backend.calls.where(
          (c) => c.startsWith('setPlaylistFolder') && c.endsWith(' null'),
        ),
        hasLength(1),
      );
    });

    testWidgets('a new folder is made from the plus of the playlists', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byTooltip('New playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Road');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('createFolder Road'));
      expect(
        find.text('This folder is empty'),
        findsOneWidget,
        reason: 'it opens on the new folder',
      );
    });
  });
}
