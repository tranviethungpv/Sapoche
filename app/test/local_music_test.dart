import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/library_controller.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/ui/collection_screen.dart' show CollectionCover;
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/cached_cover.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

LocalSong _file(
  String id, {
  String title = 'Song',
  String artist = 'Ann',
  String album = '',
  int addedAt = 1,
  bool missing = false,
}) => LocalSong(
  track: Track(
    videoId: 'local:$id',
    title: title,
    artist: artist,
    durMs: 200000,
    thumb: 'sapoche-local:local:$id',
  ),
  album: album,
  addedAt: addedAt,
  missing: missing,
);

void main() {
  group('the models', () {
    test('a song from a file is told by its id, which no video has', () {
      expect(
        const Track(
          videoId: 'local:0123456789abcdef',
          title: 't',
          artist: '',
          durMs: 1,
        ).isLocal,
        isTrue,
      );
      expect(
        const Track(
          videoId: 'dQw4w9WgXcQ',
          title: 't',
          artist: '',
          durMs: 1,
        ).isLocal,
        isFalse,
      );
    });

    test('the status, a file and a scan are read from what native sends', () {
      final status = LocalStatus.fromMap({
        'enabled': false,
        'access': 'blocked',
        'count': 4,
        'missing': ['local:a'],
      });
      expect(status.enabled, isFalse);
      expect(status.access, LocalAccess.blocked);
      expect(status.count, 4);
      expect(status.missing, {'local:a'});
      expect(LocalStatus.fromMap({}).access, LocalAccess.ask);
      expect(LocalStatus.fromMap({}).enabled, isTrue);

      final song = LocalSong.fromMap({
        'videoId': 'local:a',
        'title': 'T',
        'artist': '',
        'durMs': 5,
        'album': 'Al',
        'mime': 'audio/mpeg',
        'size': 10,
        'addedAt': 7,
        'missing': true,
      });
      expect(song.track.isLocal, isTrue);
      expect([song.album, song.mime, song.size, song.addedAt, song.missing], [
        'Al',
        'audio/mpeg',
        10,
        7,
        true,
      ]);

      final scan = LocalScan.fromMap({'total': 3, 'unsupported': 2});
      expect([scan.total, scan.unsupported], [3, 2]);
    });

    test('a backup counts the songs from files it left out', () {
      expect(BackupCounts.fromMap({'liked': 1, 'local': 3}).local, 3);
      expect(BackupCounts.fromMap({'liked': 1}).local, 0);
    });
  });

  group('the library controller', () {
    late FakeBackend backend;
    late LibraryController library;

    setUp(() async {
      backend = FakeBackend();
      library = LibraryController(backend, quiet: Duration.zero);
      await library.start();
    });

    tearDown(() => library.dispose());

    test('the status is read at once, the files only while the list is open', () async {
      backend.localSongs.add(_file('a'));
      await library.refresh();
      expect(library.localStatus.count, 1);
      expect(library.local, isEmpty);
      expect(backend.calls, isNot(contains('localTracks')));

      await library.watchLocal(true);
      expect(library.local.map((s) => s.track.videoId), ['local:a']);

      await library.watchLocal(false);
      backend.localSongs.add(_file('b'));
      backend.calls.clear();
      await library.refresh();
      expect(backend.calls, isNot(contains('localTracks')));
    });

    test('opening the list reads only the music on the phone and tells no other screen', () async {
      backend.localState = const LocalStatus(access: LocalAccess.granted);
      backend.localSongs.add(_file('a'));
      await library.refresh();
      // The mix of the hour is read on its own after a refresh, and told when it is there
      await Future<void>.delayed(Duration.zero);
      var told = 0;
      library.addListener(() => told++);
      backend.calls.clear();

      await library.watchLocal(true);
      // Not the whole library: every screen that listens to it (the home page works out its rows again, a tenth of a
      // second on a phone) would have been told for nothing
      expect(backend.calls, ['localStatus', 'localTracks']);
      expect(library.local.map((s) => s.track.videoId), ['local:a']);
      expect(told, 0);
    });

    test('a scan that finds the same files costs the other screens nothing, one that finds more tells them', () async {
      backend.localState = const LocalStatus(access: LocalAccess.granted);
      backend.localSongs.add(_file('a'));
      await library.refresh();
      await Future<void>.delayed(Duration.zero);
      await library.watchLocal(true);
      var told = 0;
      var listed = 0;
      library.addListener(() => told++);
      library.localSongs.addListener(() => listed++);
      backend.calls.clear();

      await library.scanLocal();
      expect(backend.calls, ['localScan', 'localStatus', 'localTracks']);
      expect([told, listed], [0, 0]);

      backend.localSongs.add(_file('b'));
      await library.scanLocal();
      expect(told, 1, reason: 'the count shown on the home page and in the library changed');
      expect(listed, 1);
      expect(library.local, hasLength(2));
    });

    test('nothing is read without the permission or when the switch is off', () async {
      backend.localState = const LocalStatus(access: LocalAccess.ask);
      await library.refresh();
      await library.scanLocal();
      expect(backend.calls, isNot(contains('localScan')));

      backend.localState = const LocalStatus(
        enabled: false,
        access: LocalAccess.granted,
      );
      await library.refresh();
      await library.scanLocal();
      expect(backend.calls, isNot(contains('localScan')));
    });

    test('with the permission a scan is made and its result kept', () async {
      backend.localState = const LocalStatus(access: LocalAccess.granted);
      backend.localScanResult = const LocalScan(total: 2, unsupported: 1);
      await library.refresh();
      await library.scanLocal();
      expect(backend.calls, contains('localScan'));
      expect(library.lastScan.unsupported, 1);
    });

    test('allowing the access reads the music at once', () async {
      backend.localAnswer = LocalAccess.granted;
      await library.refresh();
      await library.requestLocalAccess();
      expect(library.localStatus.access, LocalAccess.granted);
      expect(backend.calls, containsAllInOrder(['localAccess', 'localScan']));
    });

    test('a refusal does not read anything', () async {
      backend.localAnswer = LocalAccess.blocked;
      await library.requestLocalAccess();
      expect(library.localStatus.access, LocalAccess.blocked);
      expect(backend.calls, isNot(contains('localScan')));
    });

    test('a song whose file is gone is told', () async {
      backend.localSongs.addAll([_file('a'), _file('b', missing: true)]);
      await library.refresh();
      expect(library.isMissing(_file('b').track), isTrue);
      expect(library.isMissing(_file('a').track), isFalse);
    });

    test('files copied in are scanned, and counted', () async {
      backend.localState = const LocalStatus(access: LocalAccess.granted);
      backend.localImported = 3;
      await library.refresh();
      expect(await library.importLocal(), 3);
      expect(backend.calls, contains('localScan'));

      backend.calls.clear();
      backend.localImported = null;
      expect(await library.importLocal(), isNull);
      expect(backend.calls, isNot(contains('localScan')));
    });

    test('the switch is passed to the native side and read back', () async {
      await library.setLocalEnabled(false);
      expect(library.localStatus.enabled, isFalse);
      await library.setLocalEnabled(true);
      expect(library.localStatus.enabled, isTrue);
    });
  });

  group('a room', () {
    late FakeBackend backend;
    late RoomController room;
    final messages = <String>[];

    setUp(() async {
      backend = FakeBackend();
      room = RoomController(backend);
      messages.clear();
      room.messages.listen(messages.add);
      await room.start();
    });

    tearDown(() => room.dispose());

    Future<void> inRoom() async {
      backend.emit(const StateEvent(RoomSnapshot(room: 'ABCDEF')));
      await Future<void>.delayed(Duration.zero);
    }

    final local = _file('a').track;
    const youtube = Track(
      videoId: 'dQw4w9WgXcQ',
      title: 'Yt',
      artist: 'Rick',
      durMs: 1000,
    );

    test('does not take a song from a file, and says why', () async {
      await inRoom();
      await room.add(local);
      expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(messages, hasLength(1));
    });

    test('takes the songs from YouTube of a list and says what it left out', () async {
      await inRoom();
      await room.addMany([local, youtube]);
      expect(backend.calls.last, 'addMany dQw4w9WgXcQ next=false');
      await Future<void>.delayed(Duration.zero);
      expect(messages, hasLength(1));
    });

    test('sends nothing when every song of a list is from a file', () async {
      await inRoom();
      await room.playTracks([local, _file('b').track]);
      expect(backend.calls.where((c) => c.startsWith('addMany')), isEmpty);
    });

    test('outside a room the songs from files are played like any other', () async {
      await room.playTracks([local]);
      expect(backend.calls, containsAllInOrder(['clear', 'addMany local:a next=false']));
    });

    test('a song from a file gets no radio', () async {
      await room.playSong(local);
      expect(backend.calls.where((c) => c.startsWith('radio')), isEmpty);
      await room.playSong(youtube);
      expect(backend.calls.last, 'radio dQw4w9WgXcQ');
    });
  });

  group('the pictures inside the files', () {
    tearDown(() => CoverFiles.localCover = null);

    test('are read by the native side, by the id in the address', () async {
      final asked = <String>[];
      CoverFiles.localCover = (id) async {
        asked.add(id);
        return Uint8List.fromList([1, 2, 3]);
      };
      final bytes = await CoverFiles.bytes('sapoche-local:local:pic');
      expect(bytes, [1, 2, 3]);
      expect(asked, ['local:pic']);
    });

    test('a file with no picture is asked about once', () async {
      var asked = 0;
      CoverFiles.localCover = (id) async {
        asked++;
        return null;
      };
      await expectLater(
        CoverFiles.bytes('sapoche-local:local:nopic'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        CoverFiles.bytes('sapoche-local:local:nopic'),
        throwsA(isA<StateError>()),
      );
      expect(asked, 1);
    });
  });

  group('the page', () {
    Future<FakeBackend> openLibrary(
      WidgetTester tester, {
      LocalStatus status = const LocalStatus(access: LocalAccess.granted),
      List<LocalSong> songs = const [],
    }) async {
      final (backend, _) = await pumpApp(
        tester,
        prepare: (b) {
          b.localState = status;
          b.localSongs.addAll(songs);
        },
      );
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('the library has a row for it with the number of files', (tester) async {
      await openLibrary(tester, songs: [_file('a'), _file('b')]);
      expect(find.text('On this phone'), findsOneWidget);
      expect(find.text('2 songs'), findsWidgets);
    });

    testWidgets('the row is gone while the switch is off', (tester) async {
      await openLibrary(
        tester,
        status: const LocalStatus(enabled: false, access: LocalAccess.granted),
        songs: [_file('a')],
      );
      expect(find.text('On this phone'), findsNothing);
    });

    testWidgets('before the permission it offers to ask for it', (tester) async {
      final backend = await openLibrary(
        tester,
        status: const LocalStatus(access: LocalAccess.ask),
        songs: [_file('a', title: 'Hidden until allowed')],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(find.text('Play the music on your phone'), findsWidgets);
      expect(find.text('Hidden until allowed'), findsNothing);
      expect(backend.calls, isNot(contains('localScan')));

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(backend.calls, containsAllInOrder(['localAccess', 'localScan']));
      expect(find.text('Hidden until allowed'), findsOneWidget);
    });

    testWidgets('after a refusal for good it sends to the settings of the phone', (tester) async {
      final backend = await openLibrary(
        tester,
        status: const LocalStatus(access: LocalAccess.blocked),
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(find.textContaining('refused'), findsOneWidget);
      backend.localAnswer = LocalAccess.blocked;
      await tester.tap(find.text('Open phone settings'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('localAccess'));
    });

    testWidgets('lists the songs, newest first, with artist and album', (tester) async {
      await openLibrary(
        tester,
        songs: [
          _file('a', title: 'Old', addedAt: 1, album: 'First'),
          _file('b', title: 'New', addedAt: 9),
        ],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      final old = tester.getTopLeft(find.text('Old')).dy;
      final fresh = tester.getTopLeft(find.text('New')).dy;
      expect(fresh, lessThan(old));
      expect(find.text('Ann · First'), findsOneWidget);
      expect(find.text('Ann'), findsOneWidget, reason: 'no album, no dot');
    });

    testWidgets('scans when opened', (tester) async {
      final backend = await openLibrary(tester, songs: [_file('a')]);
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('localScan'));
    });

    testWidgets('a box narrows the songs, by title, artist and album', (tester) async {
      await openLibrary(
        tester,
        songs: [
          _file('a', title: 'Blue', artist: 'Ann'),
          _file('b', title: 'Red', artist: 'Ben', album: 'Sky'),
        ],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'sky');
      await tester.pumpAndSettle();
      expect(find.text('Red'), findsOneWidget);
      expect(find.text('Blue'), findsNothing);
      await tester.enterText(find.byType(TextField), 'ann');
      await tester.pumpAndSettle();
      expect(find.text('Blue'), findsOneWidget);
      expect(find.text('Red'), findsNothing);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No music found'), findsOneWidget);
    });

    testWidgets('the order can be changed', (tester) async {
      await openLibrary(
        tester,
        songs: [
          _file('a', title: 'Zed', addedAt: 9),
          _file('b', title: 'Abe', addedAt: 1),
        ],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Zed')).dy,
        lessThan(tester.getTopLeft(find.text('Abe')).dy),
      );
      await tester.tap(find.byTooltip('More').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by: Title'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Abe')).dy,
        lessThan(tester.getTopLeft(find.text('Zed')).dy),
      );
    });

    testWidgets('a song that is touched plays with the rest behind it', (tester) async {
      final backend = await openLibrary(
        tester,
        songs: [
          _file('a', title: 'One', addedAt: 9),
          _file('b', title: 'Two', addedAt: 5),
          _file('c', title: 'Three', addedAt: 1),
        ],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        containsAllInOrder(['clear', 'addMany local:b,local:c next=false']),
      );
    });

    testWidgets('a song whose file is gone is not in the list of files', (tester) async {
      await openLibrary(
        tester,
        songs: [_file('a', title: 'Here'), _file('b', title: 'Gone', missing: true)],
      );
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(find.text('Here'), findsOneWidget);
      expect(find.text('Gone'), findsNothing);
    });

    testWidgets('the menu of a song from a file has no download and no "not interested"', (tester) async {
      await openLibrary(tester, songs: [_file('a', title: 'Mine')]);
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).last);
      await tester.pumpAndSettle();
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
      expect(find.text('Not interested'), findsNothing);
    });

    /// An iPhone: the system keeps a bar under the app, a song waits in the queue (so the mini player is there), and the
    /// page is the one with nothing in it, which is too short to scroll and so never folds the bars.
    Future<FakeBackend> openEmptyOnAnIPhone(
      WidgetTester tester, {
      LocalStatus status = const LocalStatus(),
      bool ios = true,
    }) async {
      final (backend, _) = await pumpApp(
        tester,
        prepare: (b) => b.localState = status,
      );
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(top: 177, bottom: 102);
      tester.view.viewPadding = const FakeViewPadding(top: 177, bottom: 102);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      // Put back by the test itself, before the framework checks that nothing was left changed
      debugDefaultTargetPlatformOverride = ios
          ? TargetPlatform.iOS
          : TargetPlatform.android;
      backend.emit(StateEvent(sampleRoom(local: true, songs: 3, phase: 'paused')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('on an iPhone the button to add files is above the open mini player, with nothing to scroll', (tester) async {
      await openEmptyOnAnIPhone(tester);
      final button = tester.getRect(find.text('Add files'));
      final mini = tester.getRect(find.byType(MiniPlayerCapsule));
      debugDefaultTargetPlatformOverride = null;
      expect(find.byType(MiniPlayerCapsule), findsOneWidget);
      expect(button.bottom, lessThan(mini.top - 8));
      // And the page is not asking for a scroll that the person would have to know to make
      expect(find.text('Library'), findsWidgets, reason: 'the bars are as they were: open');
    });

    testWidgets('the button to allow the music is too, on an Android phone that asks for it', (tester) async {
      await openEmptyOnAnIPhone(
        tester,
        status: const LocalStatus(access: LocalAccess.ask),
        ios: false,
      );
      final button = tester.getRect(find.text('Allow'));
      final mini = tester.getRect(find.byType(MiniPlayerCapsule));
      debugDefaultTargetPlatformOverride = null;
      expect(button.bottom, lessThan(mini.top - 8));
    });

    testWidgets('the cover and the count are left out of a page with nothing to list, but not while searching', (tester) async {
      await openEmptyOnAnIPhone(tester);
      debugDefaultTargetPlatformOverride = null;
      expect(find.text('0 songs'), findsNothing);
      expect(find.byType(CollectionCover), findsNothing);
    });

    testWidgets('an empty phone says what to do', (tester) async {
      await openLibrary(tester);
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(find.text('No music found'), findsOneWidget);
      expect(find.textContaining('shorter than 30 seconds'), findsOneWidget);
    });
  });

  group('the settings', () {
    testWidgets('a switch hides the list', (tester) async {
      final (backend, _) = await pumpApp(
        tester,
        prepare: (b) =>
            b.localState = const LocalStatus(access: LocalAccess.granted),
      );
      await openTopic(tester, 'storage');
      final toggle = find.byKey(const ValueKey('local-music-switch'));
      await tester.scrollUntilVisible(toggle, 200);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(backend.localState.enabled, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    });

    testWidgets('a backup says how many songs from this phone it left out', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.backupCounts = const BackupCounts(liked: 2, local: 3);
      await openTopic(tester, 'backup');
      await tester.tap(find.text('Save your library to a file'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('3 songs from this phone were not saved'),
        findsOneWidget,
      );
    });
  });
}
