import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/listen_tracker.dart';

// The cases of ListenTrackerTest.kt

void main() {
  final heard = <(String, int)>[];
  final skipped = <String>[];
  late ListenTracker tracker;
  late ListenTracker watching;

  setUp(() {
    heard.clear();
    skipped.clear();
    tracker = ListenTracker(heard: (id, ms) => heard.add((id, ms)));
    watching = ListenTracker(skipped: (id, _) => skipped.add(id), heard: (id, ms) => heard.add((id, ms)));
  });

  test('a song counts after thirty seconds of playing', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.check(29999);
    expect(heard, isEmpty);
    tracker.check(30000);
    expect(heard, [('a', 200000)]);
  });

  test('it counts once however often it is checked', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.check(31000);
    tracker.check(90000);
    tracker.begin(null, 0, 100000);
    expect(heard, hasLength(1));
  });

  test('pauses and buffering do not count', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.setPlaying(false, 20000);
    tracker.check(500000);
    expect(heard, isEmpty);
    tracker.setPlaying(true, 500000);
    tracker.check(509999);
    expect(heard, isEmpty);
    tracker.check(510000);
    expect(heard, hasLength(1));
  });

  test('a song skipped early does not count', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.begin('b', 180000, 12000);
    tracker.setPlaying(true, 12000);
    tracker.begin(null, 0, 20000);
    expect(heard, isEmpty);
  });

  test('a song that had just passed the mark when it was skipped still counts', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.begin('b', 180000, 30500);
    expect(heard, [('a', 200000)]);
  });

  test('a short song counts at half its length', () {
    tracker.begin('clip', 20000, 0);
    tracker.setPlaying(true, 0);
    tracker.check(9999);
    expect(heard, isEmpty);
    tracker.check(10000);
    expect(heard, [('clip', 20000)]);
  });

  test('the length may become known after the song began', () {
    tracker.begin('a', 0, 0);
    tracker.setPlaying(true, 0);
    expect(tracker.msUntilHeard(0), 30000);
    tracker.setDuration(40000);
    expect(tracker.msUntilHeard(0), 20000);
    tracker.check(20000);
    expect(heard, [('a', 40000)]);
  });

  test('it says how long to wait, and nothing when there is nothing to wait for', () {
    expect(tracker.msUntilHeard(0), isNull);
    tracker.begin('a', 200000, 0);
    expect(tracker.msUntilHeard(0), isNull, reason: 'not playing yet');
    tracker.setPlaying(true, 1000);
    expect(tracker.msUntilHeard(1000), 30000);
    expect(tracker.msUntilHeard(11000), 20000);
    tracker.setPlaying(false, 11000);
    expect(tracker.msUntilHeard(11000), isNull);
    tracker.setPlaying(true, 50000);
    expect(tracker.msUntilHeard(50000), 20000, reason: 'the ten seconds already heard are kept');
    tracker.check(70000);
    expect(tracker.msUntilHeard(70000), isNull, reason: 'already counted');
  });

  test('playing with nothing loaded is ignored', () {
    tracker.setPlaying(true, 0);
    tracker.check(60000);
    expect(heard, isEmpty);
  });

  test('the same song again is a new listen', () {
    tracker.begin('a', 200000, 0);
    tracker.setPlaying(true, 0);
    tracker.check(30000);
    tracker.begin('a', 200000, 200000);
    tracker.setPlaying(true, 200000);
    tracker.check(230000);
    expect(heard, hasLength(2));
  });

  test('a song left after a few seconds was skipped', () {
    watching.begin('a', 200000, 0);
    watching.setPlaying(true, 0);
    watching.begin('b', 200000, 8000);
    expect(skipped, ['a']);
    expect(heard, isEmpty);
  });

  test('a song that was heard is not skipped, and nor is one left at once or never played', () {
    watching.begin('a', 200000, 0);
    watching.setPlaying(true, 0);
    watching.begin('b', 200000, 40000);
    watching.setPlaying(true, 40000);
    watching.begin('c', 200000, 41000);
    watching.begin('d', 200000, 100000);
    watching.begin(null, 0, 101000);
    expect(skipped, isEmpty);
  });

  test('pauses do not make a song longer when it is left', () {
    watching.begin('a', 200000, 0);
    watching.setPlaying(true, 0);
    watching.setPlaying(false, 2000);
    watching.begin('b', 200000, 600000);
    expect(skipped, isEmpty);
  });
}
