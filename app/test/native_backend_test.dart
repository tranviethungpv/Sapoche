import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';

/// The contract with UnisonBridge.kt: what crosses the platform channels and how it is read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const events = EventChannel('app.unison/state');
  const control = MethodChannel('app.unison/control');

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

  test('a playlist search and the shuffle command cross the channel', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      if (call.method == 'searchPlaylists') {
        return [
          {
            'id': 'PLabc',
            'title': 'Mix',
            'uploader': 'Anna',
            'thumb': null,
            'count': 9,
          },
        ];
      }
      return null;
    });
    final backend = NativeBackend();
    final found = await backend.searchPlaylists('mix');
    await backend.shuffle();
    expect(found.single.id, 'PLabc');
    expect((found.single.uploader, found.single.count), ('Anna', 9));
    expect(calls.map((c) => '${c.method} ${c.arguments}'), [
      'searchPlaylists {query: mix}',
      'shuffle null',
    ]);
  });
}
