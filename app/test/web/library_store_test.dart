import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/library_store.dart';

// The cases of LibraryStoreTest.kt for what the browser keeps

Track song(String id, {String? thumb}) =>
    Track(videoId: id, title: 'Song $id', artist: 'Artist', thumb: thumb ?? 'https://img/$id', durMs: 180000);

class _Disk implements LibraryDisk {
  String? json;
  var writes = 0;

  @override
  Future<String?> read() async => json;

  @override
  Future<void> write(String json) async {
    this.json = json;
    writes++;
  }
}

void main() {
  var clock = 1000;
  late LibraryStore library;
  int tick() => clock += 10;

  setUp(() {
    clock = 1000;
    library = LibraryStore(nowMs: tick);
  });

  group('likes', () {
    test('the most recently liked comes first, and liking again keeps the first time', () {
      library
        ..setLiked(song('a'), true)
        ..setLiked(song('b'), true)
        ..setLiked(song('a'), true);
      expect(library.liked().map((t) => t.videoId), ['b', 'a']);
    });

    test('taking a like back drops the song', () {
      library
        ..setLiked(song('a'), true)
        ..setLiked(song('a'), false);
      expect(library.liked(), isEmpty);
    });

    test('a song kept by a playlist stays when it is unliked', () {
      final id = library.createPlaylist('Mix', [song('a')]);
      library
        ..setLiked(song('a'), true)
        ..setLiked(song('a'), false);
      expect(library.playlistTracks(id).map((t) => t.videoId), ['a']);
    });
  });

  group('history', () {
    test('recent lists a song once with how often it was heard', () {
      library
        ..recordListen(song('a'))
        ..recordListen(song('b'))
        ..recordListen(song('a'));
      final recent = library.recent();
      expect(recent.map((e) => e.track.videoId), ['a', 'b']);
      expect(recent.first.plays, 2);
      expect(recent.last.plays, 1);
    });

    test('listens lists every listen, the latest first', () {
      library
        ..recordListen(song('a'))
        ..recordListen(song('b'))
        ..recordListen(song('a'));
      expect(library.listens().map((e) => e.track.videoId), ['a', 'b', 'a']);
    });

    test('only the last 2000 listens are kept', () {
      for (var i = 0; i < LibraryStore.historyKeep + 5; i++) {
        library.recordListen(song('s${i % 3}'));
      }
      expect(library.listens(), hasLength(LibraryStore.historyKeep));
    });

    test('clearing the history forgets the songs only it held', () {
      library
        ..setLiked(song('a'), true)
        ..recordListen(song('a'))
        ..recordListen(song('b'))
        ..clearHistory();
      expect(library.recent(), isEmpty);
      expect(library.liked().map((t) => t.videoId), ['a']);
    });
  });

  group('playlists', () {
    test('a song is in a playlist once, in the order it was added', () {
      final id = library.createPlaylist('Mix', [song('a'), song('b'), song('a')]);
      expect(library.addToPlaylist(id, [song('b'), song('c')]), 1);
      expect(library.playlistTracks(id).map((t) => t.videoId), ['a', 'b', 'c']);
    });

    test('a playlist holds at most 500 songs', () {
      final id = library.createPlaylist('Big', [for (var i = 0; i < 600; i++) song('s$i')]);
      expect(library.playlists().single.count, LibraryStore.maxPlaylist);
      expect(library.addToPlaylist(id, [song('more')]), 0);
    });

    test('the playlist changed last is first, and its cover is its first pictures, each once', () {
      final a = library.createPlaylist('A', [song('1', thumb: 't'), song('2', thumb: 't'), song('3'), song('4'), song('5'), song('6')]);
      library.createPlaylist('B', []);
      library.renamePlaylist(a, 'A2');
      final lists = library.playlists();
      expect(lists.map((p) => p.name), ['A2', 'B']);
      expect(lists.first.thumbs, ['t', 'https://img/3', 'https://img/4', 'https://img/5']);
      expect(lists.first.count, 6);
    });

    test('a name is trimmed, cut to 60 characters and never empty', () {
      library.createPlaylist('  ${'x' * 80}  ', []);
      library.createPlaylist('   ', []);
      expect(library.playlists().map((p) => p.name), ['Untitled', 'x' * 60]);
    });

    test('moving, removing and deleting', () {
      final id = library.createPlaylist('Mix', [song('a'), song('b'), song('c')]);
      library.movePlaylistItem(id, 'c', 0);
      expect(library.playlistTracks(id).map((t) => t.videoId), ['c', 'a', 'b']);
      library.movePlaylistItem(id, 'c', 99);
      expect(library.playlistTracks(id).map((t) => t.videoId), ['a', 'b', 'c']);
      library.movePlaylistItem(id, 'nope', 0);
      library.removeFromPlaylist(id, 'b');
      expect(library.playlistTracks(id).map((t) => t.videoId), ['a', 'c']);
      library.deletePlaylist(id);
      expect(library.playlists(), isEmpty);
      expect(library.playlistTracks(id), isEmpty);
    });
  });

  group('folders', () {
    test('a playlist is in one folder at most, and a deleted folder lets its playlists go', () {
      final folder = library.createFolder('Gym');
      final other = library.createFolder('Sleep');
      final list = library.createPlaylist('Mix', []);
      library.setPlaylistFolder(list, folder);
      expect(library.playlists().single.folderId, folder);
      expect(library.folders().first.id, folder, reason: 'the folder it went into was changed last');
      library.setPlaylistFolder(list, other);
      expect(library.folders().first.id, other);
      library.deleteFolder(other);
      expect(library.playlists().single.folderId, isNull);
      expect(library.folders().map((f) => f.name), ['Gym']);
    });

    test('renaming a folder moves it to the top', () {
      final a = library.createFolder('A');
      library.createFolder('B');
      library.renameFolder(a, 'A2');
      expect(library.folders().map((f) => f.name), ['A2', 'B']);
    });
  });

  group('keeping', () {
    test('what was saved comes back whole', () async {
      final disk = _Disk();
      final first = LibraryStore(disk: disk, nowMs: tick, saveAfter: Duration.zero)
        ..setLiked(song('a'), true)
        ..recordListen(song('b'));
      final folder = first.createFolder('Gym');
      final list = first.createPlaylist('Mix', [song('a'), song('c')]);
      first.setPlaylistFolder(list, folder);
      await first.flush();
      final second = LibraryStore(disk: disk, stored: disk.json, nowMs: tick);
      expect(second.liked().map((t) => t.videoId), ['a']);
      expect(second.recent().map((e) => e.track.videoId), ['b']);
      expect(second.playlists().single.folderId, folder);
      expect(second.playlistTracks(list).map((t) => t.videoId), ['a', 'c']);
      // New ids do not repeat old ones
      expect(second.createPlaylist('New', []), greaterThan(list));
    });

    test('writes wait for a pause, and a flush does not wait', () async {
      final disk = _Disk();
      final store = LibraryStore(disk: disk, saveAfter: const Duration(seconds: 30))
        ..setLiked(song('a'), true)
        ..setLiked(song('b'), true);
      expect(disk.writes, 0);
      await store.flush();
      expect(disk.writes, 1);
      await store.flush();
      expect(disk.writes, 1, reason: 'nothing changed since');
    });

    test('a document that cannot be read is an empty library', () {
      expect(LibraryStore(stored: '{not json').liked(), isEmpty);
      expect(LibraryStore(stored: '{"v":1}').playlists(), isEmpty);
    });

    test('every change is announced', () {
      var heard = 0;
      library.onChanged = () => heard++;
      library
        ..setLiked(song('a'), true)
        ..recordListen(song('a'))
        ..createFolder('F');
      expect(heard, 3);
    });
  });
}
