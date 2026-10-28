import 'dart:async';
import 'dart:convert';

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

RoomClient _client(_Room room, {String? appVersion, String key = '', void Function(String)? log}) => RoomClient(
  baseUrl: Uri.parse('https://sapoche.example'),
  roomCode: 'ABC234',
  clientId: 'device-secret',
  name: 'Me',
  clock: ClockSync(),
  nowMs: () => DateTime.now().millisecondsSinceEpoch,
  probeAuth: () async => null,
  opener: room.opener,
  create: false,
  appVersion: appVersion,
  key: key,
  log: log ?? (_) {},
);

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('the version of the app goes in every join, and is left out when it is not known', () async {
    final room = _Room(state: () => _state(17, '[]'));
    final client = _client(room, appVersion: '1.26.0')..start();
    await _settle();
    client.rename('Anna');
    await _settle();
    final joins = room.received.where((t) => t.contains('"join"')).map((t) => jsonDecode(t) as Map<String, dynamic>).toList();
    expect(joins, hasLength(2));
    expect(joins.map((j) => j['app']), ['1.26.0', '1.26.0']);
    client.close();

    final bare = _Room(state: () => _state(17, '[]'));
    final older = _client(bare)..start();
    await _settle();
    expect(jsonDecode(bare.received.firstWhere((t) => t.contains('"join"'))), isNot(contains('app')));
    older.close();
  });

  test('the key in the address of the room never reaches the log', () async {
    final lines = <String>[];
    final client = _client(_Room(state: () => _state(17, '[]')), key: 's3cret', log: lines.add)..start();
    await _settle();
    expect(lines, contains('connected to wss://sapoche.example/room/ABC234'));
    expect(lines.join('\n'), isNot(contains('s3cret')));
    client.close();
  });

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

  group('the notices of the chat', () {
    const push = '{"t":"push.set","sub":{"endpoint":"https://fcm.googleapis.com/x","keys":{"p256dh":"a","auth":"b"}},"room":"ABC234"}';
    Iterable<String> pushes(_Room room) => room.received.where((t) => t.contains('"push.'));

    test('are asked for once per connection, after the server has said it is of protocol 13', () async {
      final room = _Room(state: () => _state(13, '[]'));
      final client = _client(room)..setPush(push);
      client.start();
      await _settle();
      expect(pushes(room), [push]);
      client.close();
    });

    test('are not asked of a server that does not know them', () async {
      final room = _Room(state: () => _state(12, '[]'));
      final client = _client(room)..setPush(push);
      client.start();
      await _settle();
      expect(pushes(room), isEmpty);
      client.close();
    });

    test('are asked for at once when the person turns them on in the room, and taken back when they turn them off', () async {
      final room = _Room(state: () => _state(13, '[]'));
      final client = _client(room);
      client.start();
      await _settle();
      client.setPush(push);
      expect(pushes(room), [push]);
      client.setPush(null);
      expect(pushes(room).last, '{"t":"push.clear"}');
      client.setPush(null);
      expect(pushes(room), hasLength(2), reason: 'there is nothing to take back the second time');
      client.close();
    });
  });
}
