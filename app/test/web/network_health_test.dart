import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/network_health.dart';

void main() {
  test('a good network is never weak, and the first stall makes it weak', () {
    final health = NetworkHealth();
    expect(health.weak, isFalse);
    expect(health.onStall(10000), isTrue);
    expect(health.weak, isTrue);
    expect(health.onStall(12000), isFalse);
  });

  test('weak ends after a quiet minute with a full buffer, not before', () {
    final health = NetworkHealth()..onStall(10000);
    expect(health.tick(69000, 40000, fullyLoaded: false), isFalse);
    expect(health.tick(71000, 10000, fullyLoaded: false), isFalse);
    expect(health.tick(71000, 10000, fullyLoaded: true), isTrue);
    expect(health.weak, isFalse);
  });

  test('behind the room, the way to catch up depends on the lag and the buffer', () {
    final health = NetworkHealth();
    expect(health.catchUp(16000, 60000), isA<CatchUpJump>());
    expect(health.catchUp(5000, 15000), isA<CatchUpSeekInBuffer>());
    expect(health.catchUp(1000, 11000), isA<CatchUpSeekInBuffer>());
    expect(health.catchUp(1000, 20000), isA<CatchUpSpeed>());
    expect(health.catchUp(5000, 8000), isA<CatchUpWait>());
    expect(health.catchUp(1000, 5000), isA<CatchUpWait>());
  });

  test('a missed jump counts as a stall: weak lasts a quiet minute from it', () {
    final health = NetworkHealth()..onJumpMissed(10000, 4000);
    expect(health.weak, isTrue);
    expect(health.tick(20000, 60000, fullyLoaded: true), isFalse);
    expect(health.tick(71000, 60000, fullyLoaded: true), isTrue);
  });

  test('the time asked for a jump follows what loading took, within limits', () {
    final health = NetworkHealth();
    expect(health.loadMs, 3000);
    health.onJumpMissed(1000, 4000);
    expect(health.loadMs, 8000);
    health.onJumpMissed(2000, 9000);
    expect(health.loadMs, NetworkHealth.maxLoadMs);
    for (var i = 0; i < 10; i++) {
      health.learnLoad(200);
    }
    expect(health.loadMs, NetworkHealth.minLoadMs);
  });
}
