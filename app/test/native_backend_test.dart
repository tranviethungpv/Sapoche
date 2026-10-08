import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';

/// The contract with SapocheBridge.kt: what crosses the platform channels and how it is read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const events = EventChannel('app.sapoche/state');
  const control = MethodChannel('app.sapoche/control');

  Future<List<BackendEvent>> receive(List<String> messages) async {
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          messages.forEach(sink.success);
          sink.endOfStream();
        },
      ),
    );
    return NativeBackend().events.toList();
  }

  test('reads every kind of message the native side sends', () async {
    final received = await receive([
      '{"type":"state","room":"ABC234","connection":"connected","phase":"playing","repeat":"all","queue":[],"members":[]}',
      '{"type":"position","playing":true,"positionMs":1200,"durationMs":60000,"driftMs":-4,"speed":1.0}',
      '{"type":"error","code":"unplayable","message":"Nobody could load: X"}',
      '{"type":"invite","code":"K2A5RF"}',
      '{"type":"notice","kind":"paused","by":"Binh","title":null}',
    ]);
    expect(received, hasLength(5));
    expect((received[0] as StateEvent).snapshot.repeat, Repeat.all);
    expect((received[1] as PositionEvent).position.driftMs, -4);
    expect((received[2] as ErrorEvent).error.code, 'unplayable');
    expect((received[3] as InviteEvent).code, 'K2A5RF');
    final notice = received[4] as NoticeEvent;
    expect((notice.kind, notice.by, notice.title), ('paused', 'Binh', null));
  });

  test(
    'the sound quality crosses as its number, and comes back in the profile',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(control, (call) async {
        calls.add(call);
        return call.method == 'profile'
            ? {'name': 'Anna', 'audioQuality': 1}
            : null;
      });
      final backend = NativeBackend();
      await backend.setAudioQuality(AudioQuality.high);
      expect(calls.single.method, 'setAudioQuality');
      expect(calls.single.arguments, {'level': 2});
      expect((await backend.profile()).audioQuality, AudioQuality.normal);
    },
  );

  test('everyone who listens shares one platform subscription', () async {
    var listens = 0;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (arguments, sink) => listens++),
    );
    final backend = NativeBackend();
    final first = backend.events.listen((_) {});
    final second = backend.events.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(listens, 1);
    await first.cancel();
    await second.cancel();
  });

  test('a link result comes back as tracks, with the playlist title when there is one', () async {
    messenger.setMockMethodCallHandler(control, (call) async {
      expect(call.method, 'lookup');
      return {
        'title': 'Road trip',
        'tracks': [
          {
            'videoId': 'aaaaaaaaaaa',
            'title': 'A',
            'artist': 'x',
            'thumb': null,
            'durMs': 1000,
          },
        ],
      };
    });
    final result = await NativeBackend().lookup(
      'https://youtube.com/playlist?list=PLabcdefghijk',
    );
    expect(result?.playlistTitle, 'Road trip');
    expect(result?.tracks.single.videoId, 'aaaaaaaaaaa');
  });

  test('sends a playlist as one addMany call with plain maps', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(control, (call) async {
      seen = call;
      return null;
    });
    await NativeBackend().addMany(const [
      Track(videoId: 'aaaaaaaaaaa', title: 'A', artist: 'x', durMs: 1000),
    ], playNext: true);
    expect(seen?.method, 'addMany');
    final args = seen?.arguments as Map<Object?, Object?>;
    expect(args['next'], true);
    expect(
      (args['tracks'] as List).single,
      containsPair('videoId', 'aaaaaaaaaaa'),
    );
  });

  test('reads the chat and the reactions of the room', () async {
    final received = await receive([
      '{"type":"chat","room":"ABC234","replace":true,"messages":[{"id":1,"by":"b","name":"Binh","text":"hi","at":5,"cid":null}]}',
      '{"type":"chat","room":"ABC234","replace":false,"messages":[{"id":2,"by":"me","name":"Anna","text":"yo","at":6,"cid":"c-1"}]}',
      '{"type":"reaction","by":"b","e":"clap","n":3}',
      '{"type":"reaction","by":"b","e":"unknown","n":1}',
    ]);
    final all = received[0] as ChatEvent;
    expect((all.room, all.replace), ('ABC234', true));
    final first = all.messages.single;
    expect(
      (first.id, first.by, first.name, first.text, first.at, first.cid),
      (1, 'b', 'Binh', 'hi', 5, null),
    );
    final added = received[1] as ChatEvent;
    expect((added.replace, added.messages.single.cid), (false, 'c-1'));
    final reaction = received[2] as ReactionEvent;
    expect(
      (reaction.by, reaction.reaction, reaction.count),
      ('b', Reaction.clap, 3),
    );
    expect((received[3] as ReactionEvent).reaction, isNull);
  });

  test('a chat message and a reaction are sent with their arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return call.method == 'sendChat' ? true : null;
    });
    final backend = NativeBackend();
    expect(await backend.sendChat('hello', 'c-1'), isTrue);
    await backend.react(Reaction.heart, 4);
    expect(calls.map((c) => '${c.method} ${c.arguments}'), [
      'sendChat {text: hello, cid: c-1}',
      'react {e: heart, n: 4}',
    ]);
  });

  test('a platform error becomes a BackendException with its code', () async {
    messenger.setMockMethodCallHandler(control, (call) async {
      throw PlatformException(code: 'no_room', message: 'Not in a room');
    });
    expect(
      NativeBackend().next(),
      throwsA(isA<BackendException>().having((e) => e.code, 'code', 'no_room')),
    );
  });

  test(
    'going solo and back is sent as one call with the switch position',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(control, (call) async {
        calls.add(call);
        return null;
      });
      final backend = NativeBackend();
      await backend.setSolo(true);
      await backend.setSolo(false);
      await backend.keepPlaying();
      expect(calls.map((c) => '${c.method} ${c.arguments}'), [
        'solo {on: true}',
        'solo {on: false}',
        'keepPlaying null',
      ]);
    },
  );

  test(
    'the picture commands and the songs-only search carry their arguments',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(control, (call) async {
        calls.add(call);
        return switch (call.method) {
          'videoSurface' => 42,
          'search' => <Object?>[],
          _ => null,
        };
      });
      final backend = NativeBackend();
      await backend.setVideoMode(true);
      await backend.setVideoVisible(false);
      await backend.setVideoQuality(480);
      expect(await backend.videoSurface(), 42);
      await backend.search('lofi', songsOnly: true);
      expect(calls.map((c) => '${c.method} ${c.arguments}'), [
        'videoMode {on: true}',
        'videoVisible {visible: false}',
        'videoQuality {height: 480}',
        'videoSurface null',
        'search {query: lofi, songsOnly: true}',
      ]);
    },
  );

  test('the shuffle command crosses the channel', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return null;
    });
    final backend = NativeBackend();
    await backend.shuffle();
    expect(calls.map((c) => '${c.method} ${c.arguments}'), ['shuffle null']);
  });

  test('room info, owner actions and settings use the channel names the native side handles', () async {
    final seen = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      seen.add(call);
      if (call.method == 'roomInfo') {
        return {
          'exists': true,
          'name': 'Family',
          'members': 2,
          'playing': false,
          'title': null,
        };
      }
      return null;
    });
    final backend = NativeBackend();
    final info = await backend.roomInfo('K2A5RF');
    expect((info?.exists, info?.name, info?.members), (true, 'Family', 2));
    await backend.kick('b');
    await backend.setRoomName('Weekend');
    await backend.setGuestControl(GuestControl.add);
    await backend.setRoomAutoplay(false);
    expect(seen.map((c) => c.method), [
      'roomInfo',
      'kick',
      'roomName',
      'roomSettings',
      'roomAutoplay',
    ]);
    expect(seen[0].arguments, {'code': 'K2A5RF'});
    expect(seen[1].arguments, {'id': 'b'});
    expect(seen[2].arguments, {'name': 'Weekend'});
    expect(seen[3].arguments, {'guestControl': 'add'});
    expect(seen[4].arguments, {'on': false});
  });

  test('room info is null when the server cannot be reached', () async {
    messenger.setMockMethodCallHandler(control, (call) async {
      throw PlatformException(code: 'failed', message: 'offline');
    });
    expect(await NativeBackend().roomInfo('K2A5RF'), isNull);
  });

  test('reads the personal queue, which comes in the shape of a room without a code', () async {
    final received = await receive([
      '{"type":"state","room":null,"connection":"none","phase":"paused","repeat":"all","index":1,"name":null,"ownerId":null,"guestControl":"all","queue":[{"id":"a","videoId":"aaaaaaaaaaa","title":"One","artist":"x","thumb":null,"durMs":1000,"addedBy":""},{"id":"b","videoId":"bbbbbbbbbbb","title":"Two","artist":"x","thumb":null,"durMs":1000,"addedBy":""}],"members":[]}',
    ]);
    final snapshot = (received.single as StateEvent).snapshot;
    expect(snapshot.inRoom, isFalse);
    expect(snapshot.current?.title, 'Two');
    expect(snapshot.repeat, Repeat.all);
    expect(snapshot.ownPlayback, isTrue);
  });

  test('the picture: speed, watching and the small window use the names the native side handles', () async {
    final seen = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      seen.add(call);
      return call.method == 'pipSupported' ? true : null;
    });
    final backend = NativeBackend();
    await backend.setPlaybackSpeed(1.5);
    await backend.setVideoWatching(true, width: 720, height: 1280);
    expect(await backend.pictureInPictureSupported(), isTrue);
    await backend.enterPictureInPicture();
    expect(seen.map((c) => c.method), [
      'playbackSpeed',
      'videoWatching',
      'pipSupported',
      'pipEnter',
    ]);
    expect(seen[0].arguments, {'speed': 1.5});
    expect(seen[1].arguments, {'on': true, 'width': 720, 'height': 1280});
  });

  test(
    'a phone that does not answer about the small window has none',
    () async {
      messenger.setMockMethodCallHandler(control, (call) async => null);
      expect(await NativeBackend().pictureInPictureSupported(), isFalse);
    },
  );

  test(
    'reads the small window opening and closing, and the speed in the state',
    () async {
      final received = await receive([
        '{"type":"pip","on":true}',
        '{"type":"pip","on":false}',
        '{"type":"state","room":null,"phase":"paused","playbackSpeed":1.75,"queue":[],"members":[]}',
        '{"type":"state","room":null,"phase":"paused","queue":[],"members":[]}',
      ]);
      expect((received[0] as PipEvent).on, isTrue);
      expect((received[1] as PipEvent).on, isFalse);
      expect((received[2] as StateEvent).snapshot.playbackSpeed, 1.75);
      // An older native side says nothing of it: normal speed
      expect((received[3] as StateEvent).snapshot.playbackSpeed, 1.0);
    },
  );
}
