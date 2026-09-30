import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/library_controller.dart';
import 'package:unison/data/models.dart';

import 'fake_backend.dart';

const _a = Track(videoId: 'aaaaaaaaaaa', title: 'A', artist: 'x', durMs: 1000);
const _b = Track(videoId: 'bbbbbbbbbbb', title: 'B', artist: 'y', durMs: 2000);

void main() {
  late FakeBackend backend;
  late LibraryController library;

  setUp(() {
    backend = FakeBackend();
    library = LibraryController(backend);
  });

  tearDown(() => library.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts with what the native side has kept', () async {
    backend.likedSongs = [_b];
    backend.recentSongs = [
      HistoryEntry(track: _a, at: DateTime(2026), plays: 3),
    ];
    await library.start();

    expect(library.liked.single.videoId, _b.videoId);
    expect(library.isLiked(_b.videoId), isTrue);
    expect(library.isLiked(_a.videoId), isFalse);
    expect(library.recent.single.plays, 3);
  });

  test('liking changes the heart at once and puts the song first', () async {
    backend.likedSongs = [_b];
    await library.start();

    final done = library.toggleLike(_a);
    expect(
      library.isLiked(_a.videoId),
      isTrue,
      reason: 'before the write ends',
    );
    expect(library.liked.map((t) => t.videoId), [_a.videoId, _b.videoId]);
    await done;
    expect(backend.calls.last, 'like ${_a.videoId} true');
  });

  test('a like is taken back by tapping again', () async {
    backend.likedSongs = [_a];
    await library.start();

    await library.toggleLike(_a);
    expect(library.isLiked(_a.videoId), isFalse);
    expect(library.liked, isEmpty);
    expect(backend.calls.last, 'like ${_a.videoId} false');
  });

  test('a like that could not be written goes back and says so', () async {
    await library.start();
    final messages = <String>[];
    library.messages.listen(messages.add);

    backend.failWith = StateError('disk full');
    await library.toggleLike(_a);
    await settle();

    expect(library.isLiked(_a.videoId), isFalse);
    expect(messages, isNotEmpty);
  });

  test('a change announced by the native side is read again', () async {
    await library.start();
    backend.recentSongs = [HistoryEntry(track: _a, at: DateTime(2026))];
    backend.emit(const LibraryEvent());
    await settle();
    await settle();

    expect(library.recent.single.track.videoId, _a.videoId);
  });

  test('clearing the history empties it but keeps the likes', () async {
    backend.likedSongs = [_a];
    backend.recentSongs = [HistoryEntry(track: _a, at: DateTime(2026))];
    await library.start();

    await library.clearHistory();

    expect(library.recent, isEmpty);
    expect(library.liked, hasLength(1));
    expect(backend.calls.last, 'clearHistory');
  });

  test(
    'a native side that cannot answer leaves the lists empty, without an error',
    () async {
      backend.failWith = StateError('no database');
      await library.start();
      expect(library.liked, isEmpty);
    },
  );

  group('playlists', () {
    const c = Track(
      videoId: 'ccccccccccc',
      title: 'C',
      artist: 'z',
      durMs: 3000,
    );

    test('a new playlist is listed with its songs counted', () async {
      await library.start();
      final id = await library.createPlaylist('Road trip', [_a, _b]);

      expect(id, isNotNull);
      expect(library.playlists.single.name, 'Road trip');
      expect(library.playlists.single.count, 2);
      expect(
        backend.calls,
        contains('createPlaylist Road trip ${_a.videoId},${_b.videoId}'),
      );
    });

    test(
      'opening a playlist loads its songs, and they follow later changes',
      () async {
        await library.start();
        final id = (await library.createPlaylist('Mix', [_a]))!;
        await library.openPlaylist(id);
        expect(library.playlistTracks(id).map((t) => t.videoId), [_a.videoId]);

        expect(
          await library.addToPlaylist(id, [_a, _b]),
          1,
          reason: 'a is already there',
        );
        expect(library.playlistTracks(id).map((t) => t.videoId), [
          _a.videoId,
          _b.videoId,
        ]);
        expect(library.playlistTracks(999), isEmpty);
      },
    );

    test('a song leaves the list before the write ends', () async {
      await library.start();
      final id = (await library.createPlaylist('Mix', [_a, _b]))!;
      await library.openPlaylist(id);

      final done = library.removeFromPlaylist(id, _a);
      expect(library.playlistTracks(id).map((t) => t.videoId), [_b.videoId]);
      await done;
      expect(backend.calls, contains('removeFromPlaylist $id ${_a.videoId}'));
      expect(library.playlists.single.count, 1);
    });

    test('a song moves to its new place before the write ends', () async {
      await library.start();
      final id = (await library.createPlaylist('Mix', [_a, _b, c]))!;
      await library.openPlaylist(id);

      final done = library.movePlaylistItem(id, c, 0);
      expect(library.playlistTracks(id).map((t) => t.videoId), [
        c.videoId,
        _a.videoId,
        _b.videoId,
      ]);
      await done;
      expect(library.playlistTracks(id).map((t) => t.videoId), [
        c.videoId,
        _a.videoId,
        _b.videoId,
      ]);
      expect(backend.calls, contains('movePlaylistItem $id ${c.videoId} 0'));
    });

    test('renaming and deleting show up in the list', () async {
      await library.start();
      final id = (await library.createPlaylist('Old'))!;
      await library.renamePlaylist(id, 'New');
      expect(library.playlists.single.name, 'New');

      await library.openPlaylist(id);
      await library.deletePlaylist(id);
      expect(library.playlists, isEmpty);
      expect(
        library.playlistTracks(id),
        isEmpty,
        reason: 'nothing kept of a deleted playlist',
      );
    });

    test('a playlist that could not be made gives no id and says so', () async {
      await library.start();
      final messages = <String>[];
      library.messages.listen(messages.add);
      backend.failWith = StateError('disk full');

      expect(await library.createPlaylist('Nope'), isNull);
      await settle();
      expect(messages, isNotEmpty);
    });
  });

  group('suggestions', () {
    test('start with what the native side kept', () async {
      backend.forYouSongs = [_a, _b];
      await library.start();
      expect(library.forYou.map((t) => t.videoId), [_a.videoId, _b.videoId]);
    });

    test('a pull to refresh replaces them with the fetched ones', () async {
      backend.forYouSongs = [_a];
      backend.refreshedSongs = [_b];
      await library.start();

      expect(await library.refreshForYou(), isTrue);
      expect(library.forYou.map((t) => t.videoId), [_b.videoId]);
      expect(backend.calls, contains('refreshSuggestions'));
    });

    test('a refresh that fails keeps what was there', () async {
      backend.forYouSongs = [_a];
      await library.start();
      backend.failWith = StateError('offline');

      expect(await library.refreshForYou(), isFalse);
      expect(library.forYou.map((t) => t.videoId), [_a.videoId]);
    });

    test(
      'a change announced by the native side brings new suggestions in',
      () async {
        await library.start();
        backend.forYouSongs = [_b];
        backend.emit(const LibraryEvent());
        await settle();
        await settle();
        expect(library.forYou.map((t) => t.videoId), [_b.videoId]);
      },
    );
  });

  group('downloads', () {
    test('a song asked for shows as queued', () async {
      await library.start();
      expect(library.downloadState(_a.videoId), isNull);

      expect(await library.download([_a, _b]), isTrue);
      expect(library.downloadState(_a.videoId), DownloadState.queued);
      expect(library.downloads.map((d) => d.track.videoId), [
        _a.videoId,
        _b.videoId,
      ]);
    });

    test('on mobile data nothing starts until the person agrees', () async {
      backend.metered = true;
      await library.start();

      expect(await library.download([_a]), isFalse);
      expect(library.downloads, isEmpty);
      expect(await library.download([_a], allowMetered: true), isTrue);
      expect(library.downloadState(_a.videoId), DownloadState.queued);
    });

    test('removing one or all takes them off the list', () async {
      backend.downloadList.addAll([
        const DownloadEntry(track: _a, state: DownloadState.done, bytes: 10),
        const DownloadEntry(track: _b, state: DownloadState.done, bytes: 20),
      ]);
      await library.start();
      await library.removeDownload(_a.videoId);
      expect(library.downloads.map((d) => d.track.videoId), [_b.videoId]);
      await library.clearDownloads();
      expect(library.downloads, isEmpty);
      expect(library.downloadState(_b.videoId), isNull);
    });

    test('a download that cannot be asked for says so', () async {
      await library.start();
      final messages = <String>[];
      library.messages.listen(messages.add);
      backend.failWith = StateError('no worker');
      await library.download([_a]);
      await settle();
      expect(messages, isNotEmpty);
    });

    test(
      'storage is read from the native side, or is null when it cannot be',
      () async {
        backend.storageInfo = const StorageInfo(
          downloadCount: 3,
          downloadBytes: 1000,
        );
        expect((await library.storage())!.downloadCount, 3);
        backend.failWith = StateError('no');
        expect(await library.storage(), isNull);
      },
    );
  });
}
