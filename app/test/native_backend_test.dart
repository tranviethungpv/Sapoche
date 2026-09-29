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
    ]);
    expect(received, hasLength(4));
    expect((received[0] as StateEvent).snapshot.repeat, Repeat.all);
    expect((received[1] as PositionEvent).position.driftMs, -4);
    expect((received[2] as ErrorEvent).error.code, 'unplayable');
    expect((received[3] as InviteEvent).code, 'K2A5RF');
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
}
