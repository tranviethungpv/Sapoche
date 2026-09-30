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
}
