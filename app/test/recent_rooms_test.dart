import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/recent_rooms.dart';

void main() {
  Future<RecentRooms> load([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return RecentRooms.load();
  }

  final t0 = DateTime(2026, 9, 29, 12);

  test('starts empty', () async {
    expect((await load()).rooms, isEmpty);
  });

  test(
    'the room this device is in goes on top, and a room is listed once',
    () async {
      final recents = await load();
      recents.touch('AAAAAA', now: t0);
      recents.touch('BBBBBB', name: 'Family', now: t0);
      recents.touch('AAAAAA', now: t0.add(const Duration(hours: 1)));
      expect(recents.rooms.map((r) => r.code), ['AAAAAA', 'BBBBBB']);
      expect(recents.rooms.last.title, 'Family');
      expect(
        recents.rooms.first.title,
        'AAAAAA',
        reason: 'no name, so the code',
      );
    },
  );

  test('only the last few rooms are kept', () async {
    final recents = await load();
    for (var i = 0; i < RecentRooms.limit + 3; i++) {
      recents.touch('ROOM${i.toString().padLeft(2, '0')}', now: t0);
    }
    expect(recents.rooms, hasLength(RecentRooms.limit));
    expect(recents.rooms.first.code, 'ROOM${RecentRooms.limit + 2}');
  });

  test('a room stays in the list after a restart', () async {
    final recents = await load();
    recents.touch('AAAAAA', name: 'Family', now: t0);
    final again = await RecentRooms.load();
    expect(again.rooms.single.code, 'AAAAAA');
    expect(again.rooms.single.name, 'Family');
    expect(again.rooms.single.lastAt, t0);
  });

  test(
    'being in a room for hours does not rewrite the list on every message',
    () async {
      final recents = await load();
      var notified = 0;
      recents.touch('AAAAAA', now: t0);
      recents.addListener(() => notified++);
      recents.touch('AAAAAA', now: t0.add(const Duration(minutes: 1)));
      recents.touch('AAAAAA', now: t0.add(const Duration(minutes: 5)));
      expect(notified, 0);
      recents.touch('AAAAAA', now: t0.add(const Duration(minutes: 30)));
      expect(notified, 1, reason: 'after a while the time is refreshed');
    },
  );

  test('a new name is recorded at once', () async {
    final recents = await load();
    recents.touch('AAAAAA', now: t0);
    recents.touch(
      'AAAAAA',
      name: 'Family',
      now: t0.add(const Duration(seconds: 5)),
    );
    expect(recents.rooms.single.name, 'Family');
  });

  test('a room can be forgotten', () async {
    final recents = await load();
    recents.touch('AAAAAA', now: t0);
    recents.touch('BBBBBB', now: t0);
    recents.forget('AAAAAA');
    expect(recents.rooms.map((r) => r.code), ['BBBBBB']);
    expect((await RecentRooms.load()).rooms.map((r) => r.code), ['BBBBBB']);
    recents.forget('NOPE00'); // nothing to do, and no error
  });

  test('damaged data means an empty list, not a crash', () async {
    expect((await load({'recent_rooms': 'not json'})).rooms, isEmpty);
    expect(
      (await load({
        'recent_rooms': '[{"code":"AAAAAA"},{"code":"BBBBBB","at":5}]',
      })).rooms.map((r) => r.code),
      ['BBBBBB'],
      reason: 'an entry that makes no sense is skipped, the rest is kept',
    );
  });
}
