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
}
