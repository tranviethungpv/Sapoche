import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/clocks.dart';
import 'package:sapoche/data/web/room_client.dart';
import 'package:sapoche/data/web/room_socket.dart';

/// The pictures of the members, with the same cases as RoomClientTest.kt: a socket stands in for the server, answers
/// the join with [state] and a request for a picture with [picture].
class _Room {
  _Room({this.state, this.picture});

  final String Function()? state;
  final String Function(String text)? picture;
  final received = <String>[];
  void Function(String text)? _toClient;

  /// Says something to the client as the server would.
  void push(String text) => _toClient!(text);

  SocketOpener get opener => (url, {required onOpen, required onMessage, required onClose}) {
    _toClient = onMessage;
    final socket = _Socket((text) {
      received.add(text);
      final reply = text.contains('"join"')
          ? state?.call()
          : text.contains('"avatar.get"')
          ? picture?.call(text)
          : null;
      if (reply != null) scheduleMicrotask(() => onMessage(reply));
    });
    scheduleMicrotask(onOpen);
    return socket;
  };

  Iterable<String> get(String id) => received.where((t) => t.contains('"avatar.get"') && t.contains('"$id"'));
}

class _Socket implements RoomSocket {
  _Socket(this._onSend);

  final void Function(String text) _onSend;

  @override
  void send(String text) => _onSend(text);

  @override
  void close(int code, String reason) {}
}

String _state(int protocol, String members, {String you = 'me'}) =>
    '{"t":"state","serverNow":0,"you":"$you","protocol":$protocol,'
    '"state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":$members}';

RoomClient _client(_Room room) => RoomClient(
  baseUrl: Uri.parse('https://sapoche.example'),
  roomCode: 'ABC234',
  clientId: 'device-secret',
  name: 'Me',
  clock: ClockSync(),
  nowMs: () => DateTime.now().millisecondsSinceEpoch,
  probeAuth: () async => null,
  opener: room.opener,
  create: false,
);

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('pictures are shared and fetched once the server speaks protocol 8', () async {
    const members = '[{"id":"me","name":"Me","ready":false},{"id":"you","name":"You","ready":false,"av":"abcd1234"}]';
    final room = _Room(
      state: () => _state(8, members),
      picture: (_) => '{"t":"avatar","id":"you","av":"abcd1234","data":"UElDVA=="}',
    );
    final heard = <(String, String?, String?)>[];
    final client = _client(room);
    client.onAvatar = (id, av, data) => heard.add((id, av, data));
    client.setAvatar('TUlORQ==');
    client.start();
    await _settle();
    expect(heard, [('you', 'abcd1234', 'UElDVA==')]);
    expect(room.received.any((t) => t.contains('"avatar.set"') && t.contains('TUlORQ==')), isTrue);
    expect(room.get('you'), hasLength(1));
    expect(room.get('me'), isEmpty, reason: 'its own picture is not asked for');
    client.close();
  });

  test('its own picture is not asked for when the room lists it by a public id', () async {
    const members = '[{"id":"a1b2c3d4e5f60718","name":"Me","ready":false,"av":"ffff0000"},'
        '{"id":"you","name":"You","ready":false,"av":"abcd1234"}]';
    final room = _Room(state: () => _state(9, members, you: 'a1b2c3d4e5f60718'));
    final client = _client(room)..start();
    await _settle();
    expect(room.get('you'), hasLength(1));
    expect(room.get('a1b2c3d4e5f60718'), isEmpty);
    client.close();
  });

  test('an older server is sent no pictures, which it would answer with an error', () async {
    final room = _Room(state: () => _state(7, '[{"id":"you","name":"You","ready":false,"av":"abcd1234"}]'));
    final client = _client(room)
      ..setAvatar('TUlORQ==')
      ..start();
    await _settle();
    expect(room.received.where((t) => t.contains('avatar')), isEmpty);
    client.close();
  });

  test('a picture is fetched again only when its fingerprint changed, and dropped when it is taken away', () async {
    String members(String extra, {bool ready = false}) => '[{"id":"you","name":"You","ready":$ready$extra}]';
    final room = _Room(state: () => _state(8, members(',"av":"aaaa0001"')));
    final heard = <(String, String?, String?)>[];
    final client = _client(room);
    client.onAvatar = (id, av, data) => heard.add((id, av, data));
    client.start();
    await _settle();
    expect(room.get('you'), hasLength(1));

    // Somebody becomes ready: the list is told again with the same picture
    room.push('{"t":"members","members":${members(',"av":"aaaa0001"', ready: true)}}');
    await _settle();
    expect(room.get('you'), hasLength(1), reason: 'the same picture is not fetched twice');

    room.push('{"t":"members","members":${members(',"av":"aaaa0002"', ready: true)}}');
    await _settle();
    expect(room.get('you'), hasLength(2), reason: 'a new picture is');

    room.push('{"t":"members","members":${members('', ready: true)}}');
    await _settle();
    expect(heard, [('you', null, null)], reason: 'taking the picture away is told');
    client.close();
  });
}
