import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/models.dart';
import 'package:unison/format.dart';

void main() {
  test('parses the state the native side sends', () {
    final json = jsonDecode(
      '''
    {"type":"state","room":"ABC234","connection":"reconnecting","you":"me","phase":"playing","index":1,"trimMs":-40,
     "queue":[{"id":"q1","videoId":"aaaaaaaaaaa","title":"One","artist":"A","thumb":null,"durMs":1000,"addedBy":"me"},
              {"id":"q2","videoId":"bbbbbbbbbbb","title":"Two","artist":"B","thumb":"http://x/y.jpg","durMs":2000,"addedBy":"b"}],
     "members":[{"id":"me","name":"Anna","ready":true}]}''',
    ) as Map<String, dynamic>;
    final snapshot = RoomSnapshot.fromJson(json);
    expect(snapshot.room, 'ABC234');
    expect(snapshot.link, Link.reconnecting);
    expect(snapshot.current?.title, 'Two');
    expect(snapshot.current?.thumb, 'http://x/y.jpg');
    expect(snapshot.trimMs, -40);
    expect(snapshot.me?.name, 'Anna');
    expect(snapshot.wantsPlaying, isTrue);
  });

  test('a device outside any room has an empty snapshot', () {
    final snapshot = RoomSnapshot.fromJson({
      'type': 'state',
      'room': null,
      'connection': 'none',
    });
    expect(snapshot.inRoom, isFalse);
    expect(snapshot.link, Link.none);
    expect(snapshot.current, isNull);
    expect(snapshot.upNext, isEmpty);
  });

  test('an index past the end of the queue has no current song', () {
    final snapshot = RoomSnapshot.fromJson({
      'room': 'X',
      'index': 5,
      'queue': <dynamic>[],
    });
    expect(snapshot.current, isNull);
  });

  test('parses position with and without drift', () {
    final synced = PlayerPosition.fromJson({
      'playing': true,
      'positionMs': 12,
      'durationMs': 30,
      'driftMs': -8,
      'speed': 1.03,
    });
    expect(synced.driftMs, -8);
    expect(synced.speed, 1.03);
    final unsynced = PlayerPosition.fromJson({
      'playing': false,
      'driftMs': null,
    });
    expect(unsynced.driftMs, isNull);
    expect(unsynced.speed, 1.0);
  });

  test('formats durations', () {
    expect(formatDuration(0), '0:00');
    expect(formatDuration(187000), '3:07');
    expect(formatDuration(3723000), '1:02:03');
    expect(formatDuration(-5), '0:00');
    expect(formatDrift(12), '+12 ms');
    expect(formatDrift(-30), '−30 ms');
  });

  test('parses the repeat mode, defaulting to off', () {
    expect(
      RoomSnapshot.fromJson({'room': 'X', 'repeat': 'one'}).repeat,
      Repeat.one,
    );
    expect(RoomSnapshot.fromJson({'room': 'X'}).repeat, Repeat.off);
    expect(
      RoomSnapshot.fromJson({'room': 'X', 'repeat': 'sideways'}).repeat,
      Repeat.off,
    );
    expect(Repeat.one.next, Repeat.off);
  });

  test('a link result knows whether it is a playlist', () {
    final single = LinkResult.fromMap({
      'title': null,
      'tracks': [
        {
          'videoId': 'aaaaaaaaaaa',
          'title': 'A',
          'artist': 'x',
          'thumb': null,
          'durMs': 1,
        },
      ],
    });
    expect(single.isPlaylist, isFalse);
    expect(single.tracks.single.videoId, 'aaaaaaaaaaa');
    final list = LinkResult.fromMap({
      'title': 'Road trip',
      'tracks': <Object?>[],
    });
    expect(list.isPlaylist, isTrue);
  });

  test('listening alone puts this device on its own song, not the room\'s', () {
    final snapshot = RoomSnapshot.fromJson({
      'room': 'X',
      'index': 0,
      'solo': true,
      'soloItemId': 'q2',
      'queue': [
        for (final n in [1, 2, 3])
          {
            'id': 'q$n',
            'videoId': 'aaaaaaaaaa$n',
            'title': 'Song $n',
            'durMs': 1000,
            'addedBy': 'me',
          },
      ],
    });
    expect(snapshot.solo, isTrue);
    expect(snapshot.current?.title, 'Song 2');
    expect(snapshot.upNext.map((e) => e.title), ['Song 3']);
    expect(snapshot.myIndex, 1);
    expect(
      snapshot.index,
      0,
      reason: 'the room itself is still on the first song',
    );
  });

  test('a solo song that left the queue falls back to the room\'s place', () {
    final snapshot = RoomSnapshot.fromJson({
      'room': 'X',
      'index': 0,
      'solo': true,
      'soloItemId': 'gone',
      'queue': [
        {
          'id': 'q1',
          'videoId': 'aaaaaaaaaaa',
          'title': 'One',
          'durMs': 1,
          'addedBy': 'me',
        },
      ],
    });
    expect(snapshot.current?.title, 'One');
  });

  test('members carry their mode, and people who are away do not count as listening', () {
    final snapshot = RoomSnapshot.fromJson({
      'room': 'X',
      'members': [
        {'id': 'a', 'name': 'Anna', 'ready': true},
        {'id': 'b', 'name': 'Binh', 'ready': true, 'solo': true},
        {'id': 'c', 'name': 'Chi', 'ready': false, 'away': true},
      ],
    });
    expect(snapshot.members.map((m) => (m.solo, m.away)), [
      (false, false),
      (true, false),
      (false, true),
    ]);
    expect(snapshot.listeningCount, 2);
    expect(snapshot.awayCount, 1);
  });

  test('the picture settings and the size of the picture are read', () {
    final snapshot = RoomSnapshot.fromJson({
      'room': 'X',
      'video': true,
      'videoHeight': 480,
    });
    expect(snapshot.video, isTrue);
    expect(snapshot.videoHeight, 480);
    expect(const RoomSnapshot().video, isFalse);
    expect(const RoomSnapshot().videoHeight, 720);

    final position = PlayerPosition.fromJson({
      'videoWidth': 1280,
      'videoHeight': 720,
    });
    expect((position.videoWidth, position.videoHeight), (1280, 720));
    expect(PlayerPosition.fromJson({}).videoWidth, 0);
  });

  test('reads the name, the owner and what guests may do', () {
    final snapshot = RoomSnapshot.fromJson({
      'type': 'state',
      'room': 'ABC234',
      'connection': 'connected',
      'you': 'b',
      'name': 'Family',
      'ownerId': 'a',
      'guestControl': 'add',
      'queue': <Object?>[],
      'members': [
        {'id': 'a', 'name': 'Anna', 'ready': true, 'owner': true},
        {'id': 'b', 'name': 'Binh', 'ready': true},
      ],
    });
    expect(snapshot.name, 'Family');
    expect(snapshot.guestControl, GuestControl.add);
    expect(snapshot.iOwn, isFalse);
    expect(snapshot.ownerHere, isTrue);
    expect(
      snapshot.canControl,
      isFalse,
      reason: 'a guest of a restricted room',
    );
    expect(snapshot.members.map((m) => m.owner), [true, false]);
  });

  test('an older server without owners leaves everyone in control', () {
    final snapshot = RoomSnapshot.fromJson({
      'type': 'state',
      'room': 'ABC234',
      'you': 'b',
      'queue': <Object?>[],
      'members': [
        {'id': 'b', 'name': 'Binh', 'ready': true},
      ],
    });
    expect(snapshot.name, isNull);
    expect(snapshot.guestControl, GuestControl.all);
    expect(snapshot.canControl, isTrue);
  });

  test('who may control a restricted room', () {
    RoomSnapshot room({
      required String you,
      bool ownerAway = false,
      bool ownerIn = true,
    }) => RoomSnapshot(
      room: 'ABC234',
      you: you,
      ownerId: 'a',
      guestControl: GuestControl.add,
      members: [
        Member(
          id: 'a',
          name: 'Anna',
          ready: true,
          owner: true,
          away: ownerAway,
        ),
        if (ownerIn) const Member(id: 'b', name: 'Binh', ready: true),
      ],
    );
    expect(room(you: 'a').canControl, isTrue, reason: 'the owner');
    expect(
      room(you: 'b').canControl,
      isFalse,
      reason: 'a guest while the owner is here',
    );
    expect(
      room(you: 'b', ownerAway: true).canControl,
      isTrue,
      reason: 'the owner has gone quiet',
    );
    expect(
      const RoomSnapshot().canControl,
      isTrue,
      reason: 'outside a room nothing is limited',
    );
  });

  test(
    'outside a room, or alone in one, this device plays what the person picked',
    () {
      expect(const RoomSnapshot().ownPlayback, isTrue);
      expect(const RoomSnapshot(room: 'ABC234').ownPlayback, isFalse);
      expect(
        const RoomSnapshot(room: 'ABC234', solo: true).ownPlayback,
        isTrue,
      );
    },
  );

  test(
    'reads what the server says about a room, and the address of the server',
    () {
      final info = RoomInfo.fromMap({
        'exists': true,
        'name': 'Family',
        'members': 3,
        'playing': true,
        'title': 'Song',
      });
      expect(
        (info.exists, info.name, info.members, info.playing, info.title),
        (true, 'Family', 3, true, 'Song'),
      );
      expect(RoomInfo.fromMap({'exists': false}).exists, isFalse);
      expect(
        Profile.fromMap({'name': 'Anna', 'server': 'https://x.example'}).server,
        'https://x.example',
      );
      expect(Profile.fromMap({'name': 'Anna'}).server, isEmpty);
    },
  );
}
