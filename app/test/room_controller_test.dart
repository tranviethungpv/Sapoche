import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/room_controller.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;
  late RoomController controller;

  setUp(() async {
    backend = FakeBackend();
    controller = RoomController(backend);
    await controller.start();
  });

  tearDown(() => controller.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'loads the saved profile so the welcome screen can prefill the name',
    () {
      expect(controller.profile.name, 'Anna');
      expect(controller.ready, isFalse);
    },
  );

  test('is ready once the first state arrives', () async {
    backend.emit(const StateEvent(RoomSnapshot()));
    await settle();
    expect(controller.ready, isTrue);
    expect(controller.snapshot.inRoom, isFalse);
  });

  test('exposes the current song and what comes next', () async {
    backend.emit(StateEvent(sampleRoom(index: 1)));
    await settle();
    expect(controller.snapshot.current?.title, 'Song 1');
    expect(controller.snapshot.upNext.map((e) => e.id), ['q2']);
    expect(controller.snapshot.nameOf('b'), 'Binh');
  });

  test('play button follows the room phase', () async {
    backend.emit(StateEvent(sampleRoom(phase: 'paused')));
    await settle();
    expect(controller.isPlaying, isFalse);
    await controller.togglePlay();
    expect(backend.calls.last, 'play');

    backend.emit(StateEvent(sampleRoom(phase: 'playing')));
    await settle();
    expect(controller.isPlaying, isTrue);
    await controller.togglePlay();
    expect(backend.calls.last, 'pause');
  });

  test('preparing counts as starting, so the button shows progress', () async {
    backend.emit(StateEvent(sampleRoom(phase: 'preparing')));
    await settle();
    expect(controller.isStarting, isTrue);
  });

  test(
    'position stands still while paused and advances while playing',
    () async {
      backend.emit(
        const PositionEvent(
          PlayerPosition(positionMs: 5000, durationMs: 60000),
        ),
      );
      await settle();
      expect(controller.positionMs(), 5000);

      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 5000, durationMs: 60000),
        ),
      );
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(controller.positionMs(), inInclusiveRange(5100, 5400));
    },
  );

  test('position never runs past the end of the song', () async {
    backend.emit(
      const PositionEvent(
        PlayerPosition(playing: true, positionMs: 59990, durationMs: 60000),
      ),
    );
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controller.positionMs(), 60000);
  });

  test(
    'a seek holds the bar at the target until the player catches up',
    () async {
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 1000, durationMs: 60000),
        ),
      );
      await settle();
      await controller.seek(30000);
      expect(backend.calls.last, 'seek 30000');
      expect(controller.positionMs(), 30000);
    },
  );

  test(
    'duration falls back to the queue entry before the player knows it',
    () async {
      backend.emit(StateEvent(sampleRoom()));
      await settle();
      expect(controller.durationMs(), 200000);
    },
  );

  test('queue moves are sent as the index in the whole queue', () async {
    backend.emit(StateEvent(sampleRoom(index: 0, songs: 4)));
    await settle();
    await controller.move(controller.snapshot.queue[3], 1);
    expect(backend.calls.last, 'move q3 1');
  });

  test('an unplayable song is announced with its title', () async {
    final messages = <String>[];
    controller.messages.listen(messages.add);
    backend.emit(
      const ErrorEvent(
        ServerError('unplayable', 'Nobody could load: Blinding Lights'),
      ),
    );
    await settle();
    expect(messages, ['Nobody could play “Blinding Lights”. Skipped.']);
  });

  test('a failing command becomes a message instead of an exception', () async {
    final messages = <String>[];
    controller.messages.listen(messages.add);
    backend.failWith = BackendException('no_room', 'Not in a room');
    await controller.next();
    await settle();
    expect(messages, ['Join a room first']);
  });

  test('joining reports a failure to the caller', () async {
    backend.failWith = BackendException('failed', 'server answered 401');
    final error = await controller.join(' abc234 ', ' Anna ');
    expect(error, contains('Could not connect'));
    expect(backend.calls.last, 'join ABC234 Anna');
  });

  test('creating a room trims the name', () async {
    expect(await controller.createRoom('  Anna '), isNull);
    expect(backend.calls.last, 'createRoom Anna');
  });
}
