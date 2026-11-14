import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/clocks.dart';
import 'package:sapoche/data/web/group_session.dart';
import 'package:sapoche/data/web/player_port.dart';
import 'package:sapoche/data/web/wire.dart';

/// A player that only remembers what it was asked and plays on a clock the test turns.
class FakePlayer extends PlayerPort {
  final calls = <String>[];
  var position = 0;
  var playing = false;
  var buffering = false;

  /// Everything is held, so that seeks are quick, unless a test says otherwise.
  var bufferedMs = 0x7fffffffffff;
  Object? failNext;

  /// Decides, for each try to prepare, what it fails with (null: it loads).
  Object? Function(QueueEntry item)? failWith;

  /// Every try to prepare, the ones that failed too.
  var prepareAttempts = 0;

  @override
  Future<void> prepare(QueueEntry item, int seekToMs) async {
    prepareAttempts++;
    calls.add('prepare ${item.id} @$seekToMs');
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
    final other = failWith?.call(item);
    if (other != null) throw other;
    position = seekToMs;
  }

  @override
  void refresh(String videoId) => calls.add('refresh $videoId');

  @override
  Future<void> seekTo(int positionMs) async {
    calls.add('seek $positionMs');
    position = positionMs;
  }

  @override
  void play() {
    calls.add('play');
    playing = true;
  }

  @override
  void pause() {
    calls.add('pause');
    playing = false;
  }

  @override
  void stop() {
    calls.add('stop');
    playing = false;
  }

  @override
  void setSpeed(double speed) {}

  var volume = 1.0;
  var pausesAtEnd = false;
  var videoHeight = 0;

  @override
  void setVolume(double level) => volume = level;

  @override
  void pauseAtEnd(bool on) => pausesAtEnd = on;

  @override
  void setVideoHeight(int height) => videoHeight = height;

  @override
  void setNext(QueueEntry? item) => calls.add('next ${item?.id}');

  @override
  int positionMs() => position;

  @override
  bool isPlaying() => playing;

  @override
  bool isBuffering() => buffering;

  @override
  int bufferedPositionMs() => bufferedMs;

  void clear() => calls.clear();
}

QueueEntry item(String id) => QueueEntry(
  id: id,
  videoId: 'v$id',
  title: 'Song $id',
  artist: 'Artist',
  durMs: 180000,
  addedBy: 'a',
);

RoomState room({
  String phase = 'idle',
  int index = 0,
  int startedAt = 0,
  int positionMs = 0,
  int epoch = 1,
  int songs = 2,
  bool? waitWeak,
}) => RoomState(
  queue: [for (var i = 1; i <= songs; i++) item('$i')],
  index: index,
  phase: phase,
  startedAt: startedAt,
  positionMs: positionMs,
  epoch: epoch,
  waitWeak: waitWeak,
);

StateMessage stateOf(RoomState state) => StateMessage(
  serverNow: 0,
  you: 'me',
  state: state,
  members: const [],
  protocol: 12,
);

void main() {
  late FakePlayer player;
  late List<String> sent;
  late GroupSession session;
  late FakeAsync async;

  /// Server time and local time agree, and local time starts at 10 s so that nothing is at 0.
  void run(void Function() body) {
    fakeAsync((a) {
      async = a;
      player = FakePlayer();
      sent = [];
      final clock = ClockSync()..addSample(0, 0, 0);
      session = GroupSession(
        player: player,
        clock: clock,
        nowMs: () => 10000 + a.elapsed.inMilliseconds,
        send: sent.add,
        drift: DriftController(speedDelta: 0, seekThresholdMs: 600),
      );
      body();
      session.close();
      a.flushTimers();
    });
  }

  List<String> types() => [for (final s in sent) jsonDecode(s)['t'] as String];

  test('a device that joins a room that is playing loads the song and starts at the room position', () {
    run(() {
      // Song 1 began 5 s ago in server time, which is local time here
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000 - 5000)));
      async.elapse(const Duration(seconds: 1));
      expect(player.calls.where((c) => c.startsWith('prepare 1 @')), hasLength(1));
      expect(player.calls, contains('play'));
      expect(player.playing, isTrue);
      expect(session.isInSync, isTrue);
      // The seek went to about where the room is: 5 s + the load guess, not to 0
      final seek = player.calls.firstWhere((c) => c.startsWith('seek '));
      expect(int.parse(seek.substring(5)), inInclusiveRange(5000, 9000));
    });
  });

  test('prepare answers ready, and start plays at the scheduled moment, not before', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'preparing', epoch: 2)));
      session.onMessage(PrepareMessage(epoch: 2, index: 0, item: item('1'), seekToMs: 0));
      async.elapse(const Duration(milliseconds: 10));
      expect(types(), contains('ready'));
      expect(jsonDecode(sent.last)['epoch'], 2);

      session.onMessage(const StartMessage(epoch: 2, startAt: 10000 + 1500, positionMs: 0));
      async.elapse(const Duration(milliseconds: 1000));
      expect(player.playing, isFalse);
      async.elapse(const Duration(milliseconds: 600));
      expect(player.playing, isTrue);
      expect(session.isInSync, isTrue);
    });
  });

  test("a skip by someone else is remembered, and our own is not", () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      expect(session.changedByOther, isFalse);
      session.onMessage(PrepareMessage(epoch: 3, index: 0, item: item('1'), seekToMs: 0, by: 'other'));
      async.elapse(const Duration(milliseconds: 10));
      expect(session.changedByOther, isTrue);
      session.onMessage(PrepareMessage(epoch: 4, index: 0, item: item('1'), seekToMs: 0, by: session.snapshot.you));
      async.elapse(const Duration(milliseconds: 10));
      expect(session.changedByOther, isFalse, reason: "this device's own skip");
      session.onMessage(PrepareMessage(epoch: 5, index: 0, item: item('1'), seekToMs: 0));
      async.elapse(const Duration(milliseconds: 10));
      expect(session.changedByOther, isFalse, reason: 'the room moving on by itself');
    });
  });

  test('pause stops the player and puts it at the room position', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 2));
      expect(player.playing, isTrue);
      session.onMessage(const PauseMessage(epoch: 2, positionMs: 4200, by: 'other'));
      async.elapse(const Duration(milliseconds: 10));
      expect(player.playing, isFalse);
      expect(player.position, 4200);
      expect(session.isInSync, isFalse);
    });
  });

  test('an older epoch is ignored', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000, epoch: 5)));
      async.elapse(const Duration(seconds: 1));
      player.clear();
      session.onMessage(const PauseMessage(epoch: 3, positionMs: 100));
      async.elapse(const Duration(milliseconds: 10));
      expect(player.calls, isEmpty);
    });
  });

  test('the player ending its song is reported with the epoch of the room', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000, epoch: 4)));
      async.elapse(const Duration(seconds: 1));
      player.onEnded!();
      expect(types().last, 'ended');
      expect(jsonDecode(sent.last)['epoch'], 4);
    });
  });

  test('a song that cannot be loaded is told once and the room is told when it was a barrier', () {
    run(() {
      final events = <RoomEvent>[];
      session.events.listen(events.add);
      player.failNext = LoadFailure(LoadReason.unplayable, 'embedding is off');
      session.onMessage(stateOf(room(phase: 'preparing', epoch: 2)));
      session.onMessage(PrepareMessage(epoch: 2, index: 0, item: item('1'), seekToMs: 0));
      async.elapse(const Duration(milliseconds: 10));
      expect(types(), contains('resolveFailed'));
      expect(events.single, isA<LoadFailedEvent>());
      expect((events.single as LoadFailedEvent).reason, LoadReason.unplayable);
    });
  });

  test('a room song that could not be loaded twice is tried again by itself, from a new address, and joins the room', () {
    run(() {
      var failures = 2; // the preparation, and the load at the start
      player.failWith = (_) => failures-- > 0 ? Exception('blip') : null;
      session.onMessage(stateOf(room(phase: 'preparing', epoch: 1)));
      session.onMessage(PrepareMessage(epoch: 1, index: 0, item: item('1'), seekToMs: 0));
      async.elapse(const Duration(milliseconds: 10));
      session.onMessage(const StartMessage(epoch: 1, startAt: 11500, positionMs: 0));
      async.elapse(const Duration(seconds: 1));
      expect(player.playing, isFalse, reason: 'it could not load it');
      async.elapse(GroupSession.retryAfter + const Duration(seconds: 10));
      expect(player.playing, isTrue);
      expect(player.calls.where((c) => c.startsWith('refresh')), ['refresh v1'], reason: 'the new try asks for a new address');
    });
  });

  test('a room song YouTube will not give out is not tried again by itself', () {
    run(() {
      player.failWith = (_) => LoadFailure(LoadReason.unplayable, 'gone');
      session.onMessage(stateOf(room(phase: 'preparing', epoch: 1)));
      session.onMessage(PrepareMessage(epoch: 1, index: 0, item: item('1'), seekToMs: 0));
      async.elapse(const Duration(milliseconds: 10));
      session.onMessage(const StartMessage(epoch: 1, startAt: 11500, positionMs: 0));
      async.elapse(const Duration(minutes: 1));
      expect(player.prepareAttempts, 2, reason: 'the preparation and the load at the start, and no more');
      expect(player.calls.where((c) => c.startsWith('refresh')), isEmpty);
    });
  });

  test('alone, a song that did not load gets one more try from a new address', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      session.goSolo();
      async.elapse(const Duration(milliseconds: 500));
      var failures = 1;
      player.failWith = (_) => failures-- > 0 ? Exception('blip') : null;
      session.soloNext();
      async.elapse(const Duration(milliseconds: 500));
      expect(session.snapshot.loading, isTrue, reason: 'it shows that something is going on while it waits');
      async.elapse(GroupSession.retryAfter);
      expect(player.playing, isTrue);
      expect(player.calls.where((c) => c.startsWith('refresh')), ['refresh v2']);
      expect(session.snapshot.loading, isFalse);
    });
  });

  test('alone, a song that fails twice is told once and nothing is skipped', () {
    run(() {
      final events = <RoomEvent>[];
      session.events.listen(events.add);
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      session.goSolo();
      async.elapse(const Duration(milliseconds: 500));
      player.failWith = (_) => Exception('blip');
      session.soloNext();
      async.elapse(GroupSession.retryAfter + const Duration(milliseconds: 500));
      expect(events.whereType<LoadFailedEvent>().map((e) => e.title), ['Song 2']);
      expect(session.snapshot.loading, isFalse);
    });
  });

  test('the room advancing to the loaded song keeps playing without a reload', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      // The player moves on to song 2 by itself, then the room says so
      player.onAdvanced?.call();
      session.onMessage(const AdvanceMessage(epoch: 2, index: 1, startedAt: 10000 + 180000));
      async.elapse(const Duration(milliseconds: 10));
      expect(player.calls.where((c) => c.startsWith('prepare')), hasLength(1));
    });
  });

  test('a drift beyond the threshold is corrected by one seek', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      // The room is at 1 s; make the player 2 s ahead
      player.position += 2000;
      player.clear();
      async.elapse(const Duration(seconds: 6));
      expect(player.calls.where((c) => c.startsWith('seek ')), isNotEmpty);
    });
  });

  test('going solo tells the room and rejoining asks for the state again', () {
    run(() {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000)));
      async.elapse(const Duration(seconds: 1));
      session.goSolo();
      expect(session.isSolo, isTrue);
      expect(types(), contains('solo'));
      // The room pausing does not move a solo device
      player.clear();
      session.onMessage(const PauseMessage(epoch: 2, positionMs: 100));
      async.elapse(const Duration(milliseconds: 10));
      expect(player.calls.where((c) => c == 'pause'), isEmpty);
      sent.clear();
      session.rejoin();
      expect(types(), ['solo', 'resync']);
    });
  });

  group('a room that waits for devices that stall', () {
    void following(bool? waitWeak) {
      session.onMessage(stateOf(room(phase: 'playing', startedAt: 10000, epoch: 1, waitWeak: waitWeak)));
      async.elapse(const Duration(seconds: 4));
    }

    test('is asked to wait once for one stall', () {
      run(() {
        following(true);
        sent.clear();
        player
          ..playing = false
          ..buffering = true
          ..position = 4100;
        async.elapse(const Duration(seconds: 2));
        expect(sent.where((m) => jsonDecode(m)['t'] == 'buf'), hasLength(1));
        expect(jsonDecode(sent.firstWhere((m) => jsonDecode(m)['t'] == 'buf'))['epoch'], 1);
        async.elapse(const Duration(seconds: 5));
        expect(sent.where((m) => jsonDecode(m)['t'] == 'buf'), hasLength(1));
      });
    });

    test('is not asked when it does not wait, or the server does not know how', () {
      for (final waitWeak in [false, null]) {
        run(() {
          following(waitWeak);
          sent.clear();
          player
            ..playing = false
            ..buffering = true;
          async.elapse(const Duration(seconds: 3));
          expect(sent.where((m) => jsonDecode(m)['t'] == 'buf'), isEmpty, reason: 'waitWeak=$waitWeak');
        });
      }
    });

    test('hears when it stopped for this device, and says when enough is loaded', () {
      run(() {
        following(true);
        player.bufferedMs = 0;
        session.onMessage(const PauseMessage(epoch: 2, positionMs: 4100, by: 'me', why: 'wait'));
        async.elapse(const Duration(seconds: 3));
        expect(sent.where((m) => jsonDecode(m)['t'] == 'buf.ok'), isEmpty);
        player.bufferedMs = player.position + 11000;
        async.elapse(const Duration(seconds: 1));
        final ok = sent.where((m) => jsonDecode(m)['t'] == 'buf.ok').toList();
        expect(ok, hasLength(1));
        expect(jsonDecode(ok.single)['epoch'], 2);
      });
    });

    test('tells who it waits for, and not that someone paused', () {
      run(() {
        following(true);
        final events = <RoomEvent>[];
        session.events.listen(events.add);
        session.onMessage(const PauseMessage(epoch: 2, positionMs: 4100, by: 'dev-b', why: 'wait'));
        async.elapse(const Duration(milliseconds: 10));
        expect(events.single, isA<WaitingEvent>());
        session.onMessage(const StartMessage(epoch: 2, startAt: 20000, positionMs: 4100, why: 'wait'));
        async.elapse(const Duration(seconds: 2));
        session.onMessage(const PauseMessage(epoch: 3, positionMs: 6000, by: 'dev-b'));
        async.elapse(const Duration(milliseconds: 10));
        expect(events.last, isA<PausedEvent>());
      });
    });
  });
}
