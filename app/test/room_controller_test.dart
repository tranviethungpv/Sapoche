import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/recent_rooms.dart';
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

  test('the repeat button cycles off, all, one, off', () async {
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat all');

    backend.emit(StateEvent(sampleRoom(repeat: Repeat.all)));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat one');

    backend.emit(StateEvent(sampleRoom(repeat: Repeat.one)));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat off');
  });

  test('an invitation link is handed to the UI once', () async {
    backend.emit(const InviteEvent('K2A5RF'));
    await settle();
    expect(controller.invite.value, 'K2A5RF');
  });

  test('sharing sends the code and a link that opens the app', () async {
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await controller.shareInvite();
    expect(backend.calls.last, contains('ABC234'));
    expect(backend.calls.last, contains('unison://join/ABC234'));
  });

  test('sharing does nothing outside a room', () async {
    await controller.shareInvite();
    expect(backend.calls.where((c) => c.startsWith('share')), isEmpty);
  });

  test('renaming trims the name', () async {
    await controller.rename('  Binh ');
    expect(backend.calls.last, 'rename Binh');
  });

  test('a playlist goes to the room in one call', () async {
    const tracks = [
      Track(videoId: 'aaaaaaaaaaa', title: 'A', artist: 'x', durMs: 1),
      Track(videoId: 'bbbbbbbbbbb', title: 'B', artist: 'x', durMs: 1),
    ];
    await controller.addMany(tracks, playNext: true);
    expect(backend.calls.last, 'addMany aaaaaaaaaaa,bbbbbbbbbbb next=true');
  });

  group('listening alone', () {
    test(
      'a pause by someone else offers to keep playing, a skip does not',
      () async {
        final notices = <Notice>[];
        controller.notices.listen(notices.add);
        backend.emit(const NoticeEvent(kind: 'paused', by: 'Binh'));
        backend.emit(
          const NoticeEvent(
            kind: 'skipped',
            by: 'Binh',
            title: 'Blinding Lights',
          ),
        );
        await settle();
        expect(notices.map((n) => n.text), [
          'Binh paused the room',
          'Binh switched to Blinding Lights',
        ]);
        expect(notices.map((n) => n.canKeepPlaying), [true, false]);
      },
    );

    test(
      'the play button follows this device\'s own player, not the room',
      () async {
        backend.emit(StateEvent(sampleRoom(phase: 'paused', solo: true)));
        backend.emit(const PositionEvent(PlayerPosition(playing: true)));
        await settle();
        expect(
          controller.isPlaying,
          isTrue,
          reason: 'the room is paused but I am playing',
        );
        await controller.togglePlay();
        expect(backend.calls.last, 'pause');
        expect(
          controller.isPlaying,
          isFalse,
          reason: 'shown at once, before the player reports',
        );
      },
    );

    test('the switch and the notice action reach the backend', () async {
      await controller.setSolo(true);
      await controller.keepPlaying();
      await controller.setSolo(false);
      expect(
        backend.calls,
        containsAllInOrder(['solo true', 'keepPlaying', 'solo false']),
      );
    });
  });

  test(
    'outside a room the play button follows this device\'s own player',
    () async {
      backend.emit(const StateEvent(RoomSnapshot()));
      await settle();
      expect(controller.isPlaying, isFalse);
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 1000, durationMs: 60000),
        ),
      );
      await settle();
      expect(controller.isPlaying, isTrue);
      await controller.togglePlay();
      expect(backend.calls.last, 'pause');
      expect(
        controller.isPlaying,
        isFalse,
        reason: 'shown at once, before the player reports back',
      );
      expect(controller.isStarting, isFalse);
    },
  );

  test(
    'rooms are remembered when this device is in them, with their name',
    () async {
      SharedPreferences.setMockInitialValues({});
      final recents = await RecentRooms.load();
      final remembering = RoomController(backend, recents: recents);
      await remembering.start();
      backend.emit(const StateEvent(RoomSnapshot()));
      await settle();
      expect(
        recents.rooms,
        isEmpty,
        reason: 'nothing to remember outside a room',
      );
      backend.emit(StateEvent(sampleRoom(name: 'Family')));
      await settle();
      expect(recents.rooms.single.code, 'ABC234');
      expect(recents.rooms.single.name, 'Family');
      remembering.dispose();
    },
  );

  test(
    'the invitation link lives on the server, or falls back to the app\'s own',
    () async {
      expect(controller.inviteLink('K2A5RF'), 'unison://join/K2A5RF');
      backend.profileValue = const Profile(
        name: 'Anna',
        server: 'https://x.example',
      );
      final withServer = RoomController(backend);
      await withServer.start();
      expect(withServer.inviteLink('K2A5RF'), 'https://x.example/join/K2A5RF');
      withServer.dispose();
    },
  );

  test('sharing an invitation sends the code and the link', () async {
    backend.profileValue = const Profile(
      name: 'Anna',
      server: 'https://x.example',
    );
    final sharing = RoomController(backend);
    await sharing.start();
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await sharing.shareInvite();
    expect(backend.calls.last, contains('ABC234'));
    expect(backend.calls.last, contains('https://x.example/join/ABC234'));
    sharing.dispose();
  });

  test('room settings and removals go to the native side', () async {
    await controller.setRoomName('  Weekend ');
    expect(backend.calls.last, 'roomName Weekend');
    await controller.setGuestControl(GuestControl.add);
    expect(backend.calls.last, 'guestControl add');
    await controller.kick(const Member(id: 'b', name: 'Binh', ready: true));
    expect(backend.calls.last, 'kick b');
  });

  test(
    'autoplay is on until turned off, and the choice goes to the native side',
    () async {
      expect(controller.autoplay, isTrue);
      await controller.setAutoplay(false);
      expect(controller.autoplay, isFalse);
      expect(backend.calls.last, 'autoplay false');
    },
  );

  test(
    'completions come from the backend, and a failing one is just empty',
    () async {
      backend.suggestions = ['lofi girl', 'lofi beats'];
      expect(await controller.suggest('lofi'), ['lofi girl', 'lofi beats']);
      backend.failWith = StateError('offline');
      expect(await controller.suggest('lofi'), isEmpty);
    },
  );
}
