import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/local_session.dart';
import 'package:sapoche/data/web/player_port.dart';
import 'package:sapoche/data/web/wire.dart';

import 'group_session_test.dart' show FakePlayer;

TrackRef song(String id, {int durMs = 180000}) => TrackRef('v$id', 'Song $id', 'Artist', null, durMs);

void main() {
  late FakePlayer player;
  late List<SavedQueue> saved;
  late List<Problem> problems;
  late List<QueueEntry> ended;
  late LocalSession session;
  late FakeAsync async;
  var counter = 0;

  void run(void Function() body, {SavedQueue? from}) {
    fakeAsync((a) {
      async = a;
      player = FakePlayer();
      saved = [];
      problems = [];
      ended = [];
      counter = 0;
      session = LocalSession(
        player: player,
        saved: from,
        persist: saved.add,
        problem: problems.add,
        onQueueEnd: ended.add,
        newId: () => 'id${++counter}',
        random: Random(1),
      )..attach();
      body();
      a.flushTimers();
    });
  }

  List<String> titles() => [for (final e in session.snapshot.queue) e.title];

  test('dropping played songs keeps the one playing and those to come', () {
    run(() {
      session.add([song('1'), song('2'), song('3'), song('4')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.jump(session.snapshot.queue[2].id);
      async.elapse(const Duration(milliseconds: 10));
      session.dropPlayed(10);
      async.elapse(const Duration(milliseconds: 10));
      expect(titles(), ['Song 3', 'Song 4']);
      expect(session.snapshot.index, 0);
    });
  });

  test('once the queue has finished all of it may be dropped, oldest first', () {
    run(() {
      session.add([song('1'), song('2'), song('3')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.jump(session.snapshot.queue[2].id);
      async.elapse(const Duration(milliseconds: 10));
      player.onEnded?.call();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.finished, isTrue);
      session.dropPlayed(2);
      session.dropPlayed(0);
      session.dropPlayed(-5);
      expect(titles(), ['Song 3']);
      expect(session.snapshot.index, 0);
    });
  });

  test('adding to an empty queue starts the first song', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      expect(titles(), ['Song 1', 'Song 2']);
      expect(player.calls.where((c) => c.startsWith('prepare id1')), hasLength(1));
      expect(player.playing, isTrue);
      expect(session.snapshot.loading, isFalse);
      expect(saved, isNotEmpty);
    });
  });

  test('the same song is not added twice while it is waiting, but may be added again once played', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      session.add([song('2'), song('3')], next: false);
      expect(titles(), ['Song 1', 'Song 2', 'Song 3']);
      session.next(); // on song 2 now: song 1 was played
      async.elapse(const Duration(milliseconds: 10));
      session.add([song('1')], next: false);
      expect(titles().last, 'Song 1');
    });
  });

  test('next and previous move along the queue, and previous restarts a song that is well along', () {
    run(() {
      session.add([song('1'), song('2'), song('3')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.next();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.current!.title, 'Song 2');
      player.position = 10000;
      player.clear();
      session.prev();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.current!.title, 'Song 2', reason: 'a song that is well along only starts over');
      expect(player.calls, contains('seek 0'));
      player.position = 500;
      session.prev();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.current!.title, 'Song 1');
    });
  });

  test('the end of the last song finishes the queue, tells autoplay, and play starts it again', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.next();
      async.elapse(const Duration(milliseconds: 10));
      player.onEnded!();
      expect(session.snapshot.finished, isTrue);
      expect(ended.single.title, 'Song 2');
      expect(player.playing, isFalse);
      session.play();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.finished, isFalse);
      expect(session.snapshot.current!.title, 'Song 1');
      expect(player.playing, isTrue);
    });
  });

  test('repeat all goes round, repeat one stays on the song that ended', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.setRepeat('all');
      session.next();
      async.elapse(const Duration(milliseconds: 10));
      player.onEnded!();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.current!.title, 'Song 1');
      session.setRepeat('one');
      player.onEnded!();
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.current!.title, 'Song 1');
      expect(session.snapshot.finished, isFalse);
    });
  });

  test('removing the song that plays moves on to the next in its place, still playing', () {
    run(() {
      session.add([song('1'), song('2'), song('3')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.remove('id1');
      async.elapse(const Duration(milliseconds: 10));
      expect(titles(), ['Song 2', 'Song 3']);
      expect(session.snapshot.current!.title, 'Song 2');
      expect(player.playing, isTrue);
    });
  });

  test('a song YouTube will not play is skipped, and the next one plays', () {
    run(() {
      player.failNext = LoadFailure(LoadReason.unplayable, 'blocked');
      session.add([song('1'), song('2'), song('3')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      expect(problems.single.kind, ProblemKind.skipped);
      expect(session.snapshot.current!.title, 'Song 2');
      expect(player.playing, isTrue);
    });
  });

  test('a stream that keeps breaking is given up on, and told as the connection', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(seconds: 1));
      for (var i = 0; i < 4; i++) {
        player.onError?.call(Exception('403'));
        async.elapse(const Duration(milliseconds: 10));
      }
      expect(session.snapshot.current!.title, 'Song 2');
      expect(problems.map((p) => p.kind), [ProblemKind.broken]);
    });
  });

  test('three songs in a row that cannot be played stop the skipping', () {
    run(() {
      session = LocalSession(
        player: _FailingPlayer(3),
        persist: (_) {},
        problem: problems.add,
        newId: () => 'id${++counter}',
      )..attach();
      session.add([song('1'), song('2'), song('3'), song('4')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      expect(problems.map((p) => p.kind), [ProblemKind.skipped, ProblemKind.skipped, ProblemKind.unplayable]);
      expect(session.snapshot.current!.title, 'Song 3', reason: 'it stays where it stopped');
    });
  });

  test('a song that could not load because the device is offline is kept, and play tries again', () {
    run(() {
      player.failNext = LoadFailure(LoadReason.offline, 'no network');
      session.add([song('1')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      expect(problems.single.kind, ProblemKind.offline);
      expect(session.snapshot.queue, hasLength(1));
      expect(player.playing, isFalse);
      session.play();
      async.elapse(const Duration(milliseconds: 10));
      expect(player.playing, isTrue);
    });
  });

  test('shuffle as a mode mixes what is to come, and turning it off puts the songs back, added ones after them', () {
    run(() {
      session.add([for (var i = 1; i <= 8; i++) song('$i')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.setShuffle(true);
      expect(titles().first, 'Song 1', reason: 'the song that plays stays');
      expect(titles().toSet(), {for (var i = 1; i <= 8; i++) 'Song $i'});
      session.add([song('9')], next: false);
      session.setShuffle(false);
      expect(titles(), [for (var i = 1; i <= 9; i++) 'Song $i']);
    });
  });

  test('the queue is written down and read again, paused where it was', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 10));
      session.next();
      async.elapse(const Duration(milliseconds: 10));
      player.position = 42000;
      session.pause();
      final last = saved.last;
      expect(last.index, 1);
      expect(last.positionMs, 42000);

      final again = SavedQueue.fromJson(last.toJson())!;
      final fresh = LocalSession(player: FakePlayer(), saved: again, persist: (_) {});
      expect(fresh.snapshot.current!.title, 'Song 2');
      expect(fresh.restoredPositionMs, 42000);
      expect(fresh.snapshot.loading, isFalse);
    });
  });

  test('a queue that is full says so instead of adding', () {
    run(() {
      final many = [for (var i = 0; i < LocalSession.maxQueue; i++) song('$i')];
      session.add(many, next: false);
      async.elapse(const Duration(milliseconds: 10));
      expect(session.snapshot.queue, hasLength(LocalSession.maxQueue));
      session.add([song('extra')], next: false);
      expect(problems.single.kind, ProblemKind.queueFull);
    });
  });

  test('a song that did not load gets one more try from a new address, and plays if that works', () {
    run(() {
      var failures = 1;
      player.failWith = (_) => failures-- > 0 ? Exception('blip') : null;
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 500));
      expect(player.playing, isFalse);
      expect(session.snapshot.loading, isTrue, reason: 'it shows that something is going on while it waits');
      expect(problems, isEmpty, reason: 'a blip is not said to the person');
      async.elapse(LocalSession.retryAfter);
      expect(player.playing, isTrue);
      expect(session.snapshot.current!.title, 'Song 1');
      expect(player.calls.where((c) => c.startsWith('refresh')), ['refresh v1'], reason: 'the second try starts from a new stream address');
      expect(player.prepareAttempts, 2);
    });
  });

  test('a song that fails twice is skipped to the next', () {
    run(() {
      player.failWith = (i) => i.title == 'Song 1' ? Exception('blip') : null;
      session.add([song('1'), song('2')], next: false);
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(session.snapshot.current!.title, 'Song 2');
      expect(player.playing, isTrue);
      expect(problems.map((p) => p.kind), [ProblemKind.broken]);
    });
  });

  test('skipping because songs fail to load stops after a few in a row, with the failure said', () {
    run(() {
      player.failWith = (_) => Exception('the network is a mess');
      session.add([for (var i = 1; i <= 6; i++) song('$i')], next: false);
      async.elapse((LocalSession.retryAfter + const Duration(milliseconds: 500)) * 4);
      expect(problems.map((p) => p.kind), [ProblemKind.broken, ProblemKind.broken, ProblemKind.failed]);
      expect(session.snapshot.current!.title, 'Song 3');
      expect(player.playing, isFalse);
      expect(session.snapshot.loading, isFalse);
      expect(player.prepareAttempts, 6, reason: 'two tries for each of three songs, and no more');
    });
  });

  test('songs that will not play and songs that did not load count together towards stopping', () {
    run(() {
      player.failWith = (i) => i.title == 'Song 2' ? Exception('blip') : LoadFailure(LoadReason.unplayable, 'gone');
      session.add([for (var i = 1; i <= 6; i++) song('$i')], next: false);
      async.elapse((LocalSession.retryAfter + const Duration(milliseconds: 500)) * 2);
      expect(problems.map((p) => p.kind), [ProblemKind.skipped, ProblemKind.broken, ProblemKind.unplayable]);
      expect(session.snapshot.current!.title, 'Song 3');
    });
  });

  test('the last song of the list is not skipped when it fails, so no queue ends because of a network', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 100));
      var failures = 2;
      player.failWith = (_) => failures-- > 0 ? Exception('blip') : null;
      session.next();
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(problems.last.kind, ProblemKind.failed);
      expect(session.snapshot.current!.title, 'Song 2');
      expect(session.snapshot.finished, isFalse);
      expect(ended, isEmpty);
    });
  });

  test('repeating all goes round to the first song when the last fails, and a single song is not looped through', () {
    run(() {
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 100));
      session.setRepeat('all');
      player.failWith = (i) => i.title == 'Song 2' ? Exception('blip') : null;
      session.next();
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(session.snapshot.current!.title, 'Song 1');
      expect(problems.last.kind, ProblemKind.broken);
    });
    run(() {
      session.add([song('1')], next: false);
      async.elapse(const Duration(milliseconds: 100));
      session.setRepeat('all');
      final before = player.prepareAttempts;
      player.failWith = (_) => Exception('blip');
      session.jump(session.snapshot.queue[0].id);
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(problems.last.kind, ProblemKind.failed);
      expect(player.prepareAttempts - before, 2, reason: 'two tries, and no looping round to the same song');
    });
  });

  test('pausing while the retry waits leaves it paused and says nothing; another song chosen drops the retry', () {
    run(() {
      var failures = 1;
      player.failWith = (_) => failures-- > 0 ? Exception('blip') : null;
      session.add([song('1'), song('2')], next: false);
      async.elapse(const Duration(milliseconds: 500));
      session.pause();
      async.elapse(LocalSession.retryAfter * 2);
      expect(problems, isEmpty);
      expect(player.playing, isFalse);
      expect(session.snapshot.loading, isFalse);
      expect(session.snapshot.current!.title, 'Song 1', reason: 'no skipping to the next either');
      session.play();
      async.elapse(const Duration(milliseconds: 100));
      expect(player.playing, isTrue, reason: 'play starts it again, from a new address');
    });
    run(() {
      player.failWith = (i) => i.title == 'Song 1' ? Exception('blip') : null;
      session.add([song('1'), song('2'), song('3')], next: false);
      async.elapse(const Duration(milliseconds: 500));
      session.jump(session.snapshot.queue[2].id);
      async.elapse(LocalSession.retryAfter * 3);
      expect(session.snapshot.current!.title, 'Song 3');
      expect(problems, isEmpty);
      expect(player.prepareAttempts, 2, reason: 'the dropped song was not tried a second time');
    });
  });

  test('a song that will not play, or the lack of a network, is not tried again at once', () {
    run(() {
      player.failWith = (_) => LoadFailure(LoadReason.unplayable, 'gone');
      session.add([song('1')], next: false);
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(player.prepareAttempts, 1);
    });
    run(() {
      player.failWith = (_) => LoadFailure(LoadReason.offline, 'no network');
      session.add([song('1')], next: false);
      async.elapse(LocalSession.retryAfter + const Duration(milliseconds: 500));
      expect(player.prepareAttempts, 1);
    });
  });

  for (final transientOnly in [true, false]) {
    test('random taps among ${transientOnly ? 'random blips never end the queue' : 'every kind of failure never'} or leave it loading for ever', () {
      for (var seed = 1; seed <= 40; seed++) {
        run(() {
          final random = Random(seed);
          player.failWith = (_) {
            if (random.nextInt(10) >= 4) return null;
            return switch (transientOnly ? 0 : random.nextInt(3)) {
              0 => Exception('blip'),
              1 => LoadFailure(LoadReason.unplayable, 'gone'),
              _ => LoadFailure(LoadReason.offline, 'no network'),
            };
          };
          session.add([for (var i = 1; i <= 8; i++) song('$i')], next: false);
          for (var step = 0; step < 150; step++) {
            final s = session.snapshot;
            final queue = s.queue;
            final pastTheEnd = s.index + 1 >= queue.length && s.repeat != 'all';
            switch (random.nextInt(13)) {
              case 0 || 1:
                if (!pastTheEnd) session.next();
              case 2:
                session.prev();
              case 3:
                session.pause();
              case 4 || 5:
                session.play();
              case 6 || 7:
                if (queue.isNotEmpty) session.jump(queue[random.nextInt(queue.length)].id);
              case 8:
                session.setRepeat(['off', 'all', 'one'][random.nextInt(3)]);
              case 9:
                session.add([song('${9 + random.nextInt(30)}')], next: random.nextBool());
              case 10:
                if (queue.length > 1 && s.index < queue.length - 1) session.remove(queue[random.nextInt(queue.length)].id);
              case 11:
                player.onError?.call(Exception('403'));
              default:
                session.seek(random.nextInt(100000));
            }
            async.elapse(Duration(milliseconds: random.nextInt(5000)));
            if (transientOnly) expect(ended, isEmpty, reason: 'seed $seed: a blip ended the queue, which would start autoplay');
          }
          player.failWith = null;
          async.elapse(const Duration(minutes: 2));
          expect(session.snapshot.loading, isFalse, reason: 'seed $seed: it is still loading');
        });
      }
    });
  }

  test('a load that is slow is said to be slow', () {
    run(() {
      // A player that never answers
      session = LocalSession(player: _SlowPlayer(), persist: (_) {}, problem: problems.add)..attach();
      session.add([song('1')], next: false);
      async.elapse(const Duration(seconds: 9));
      expect(problems.single.kind, ProblemKind.slow);
    });
  });
}

class _SlowPlayer extends FakePlayer {
  @override
  Future<void> prepare(QueueEntry item, int seekToMs) => Future<void>.delayed(const Duration(minutes: 5));
}

/// A player whose first [failures] loads are refused as unplayable.
class _FailingPlayer extends FakePlayer {
  _FailingPlayer(this.failures);
  int failures;

  @override
  Future<void> prepare(QueueEntry item, int seekToMs) async {
    if (failures-- > 0) throw LoadFailure(LoadReason.unplayable, 'blocked');
    return super.prepare(item, seekToMs);
  }
}
