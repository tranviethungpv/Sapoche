import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/sleep_timer.dart';

// The cases of SleepTimerTest.kt, for the Dart copy

void main() {
  late FakeAsync async;
  late SleepTimer timer;
  late List<String> calls;
  late List<double> volumes;
  late bool atSongEnd;
  const start = 1000000;

  // The timers must be made inside the fake zone, so each test builds its own world there
  void sleepTest(String name, void Function() body) => test(name, () {
    fakeAsync((a) {
      async = a;
      calls = [];
      volumes = [];
      atSongEnd = false;
      timer = SleepTimer(
        wallClock: () => start + async.elapsed.inMilliseconds,
        stop: () => calls.add('stop'),
        fade: volumes.add,
        pauseAtSongEnd: (on) => atSongEnd = on,
      );
      body();
    });
  });

  void pass(int ms) => async.elapse(Duration(milliseconds: ms));

  sleepTest('it stops when the time is up and not before', () {
    timer.startIn(10);
    expect(timer.state.mode, SleepMode.time);
    expect(timer.state.endsAt, DateTime.fromMillisecondsSinceEpoch(start + 600000));
    pass(599999);
    expect(calls, isEmpty);
    pass(1);
    expect(calls, ['stop']);
    expect(timer.state.on, isFalse);
  });

  sleepTest('the volume goes down over the last seconds and comes back after the stop', () {
    timer.startIn(1);
    volumes.clear();
    pass(44000);
    expect(volumes, isEmpty, reason: 'full volume until the fade starts');
    pass(1000); // the fade starts at 45 s
    expect(volumes.first, 1.0);
    pass(15000);
    expect(calls, ['stop']);
    final down = volumes.sublist(0, volumes.length - 1);
    for (var i = 1; i < down.length; i++) {
      expect(down[i], lessThanOrEqualTo(down[i - 1]), reason: '$volumes');
    }
    expect(volumes.last, 1.0);
    expect(volumes.reduce((a, b) => a < b ? a : b), lessThan(0.1), reason: '$volumes');
  });

  sleepTest('cancelling stops nothing and gives the volume back', () {
    timer.startIn(5);
    pass(290000); // in the fade
    timer.cancel();
    volumes.clear();
    pass(600000);
    expect(calls, isEmpty);
    expect(timer.state.on, isFalse);
    expect(volumes, isEmpty);
  });

  sleepTest('a new setting replaces the old one', () {
    timer.startIn(5);
    pass(240000);
    timer.startIn(30);
    pass(600000);
    expect(calls, isEmpty);
    pass(1200000);
    expect(calls, ['stop']);
  });

  sleepTest('at the end of the song it asks the player to pause there and stops when told it did', () {
    timer.startAtSongEnd();
    expect(atSongEnd, isTrue);
    expect(timer.state.mode, SleepMode.song);
    pass(3600000); // time does not matter
    expect(calls, isEmpty);
    timer.songEnded();
    expect(calls, ['stop']);
    expect(timer.state.on, isFalse);
    expect(atSongEnd, isFalse);
  });

  sleepTest('a song ending means nothing to a timer set in minutes', () {
    timer.startIn(10);
    timer.songEnded();
    expect(calls, isEmpty);
    expect(timer.state.mode, SleepMode.time);
  });

  sleepTest('turning it off after choosing the song end lets the player carry on', () {
    timer.startAtSongEnd();
    timer.cancel();
    expect(atSongEnd, isFalse);
    timer.songEnded();
    expect(calls, isEmpty);
  });

  sleepTest('a tab that was slowed down still stops at the hour, not a step late', () {
    timer.startIn(1);
    // The browser wakes the timers once, long after the fade should have been over
    pass(75000);
    expect(calls, ['stop']);
  });
}
