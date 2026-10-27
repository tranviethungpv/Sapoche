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
  Object? failNext;

  @override
  Future<void> prepare(QueueEntry item, int seekToMs) async {
    calls.add('prepare ${item.id} @$seekToMs');
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
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
}) => RoomState(
  queue: [for (var i = 1; i <= songs; i++) item('$i')],
  index: index,
  phase: phase,
  startedAt: startedAt,
  positionMs: positionMs,
  epoch: epoch,
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
}
