import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/group_session.dart';
import 'package:sapoche/data/web/wire.dart';

GroupSnapshot _snapshot({
  String guestControl = 'all',
  String? you = 'guest',
  bool ownerAway = false,
  bool solo = false,
}) => GroupSnapshot(
  state: RoomState(
    queue: const [],
    index: 0,
    phase: 'idle',
    startedAt: 0,
    positionMs: 0,
    epoch: 1,
    ownerId: 'owner',
    guestControl: guestControl,
  ),
  members: [
    Member(
      id: 'owner',
      name: 'Owner',
      ready: true,
      owner: true,
      away: ownerAway,
    ),
    const Member(id: 'guest', name: 'Guest', ready: true),
  ],
  you: you,
  solo: solo,
);

void main() {
  group('GroupSnapshot.canSteer', () {
    test('outside a room everything is allowed', () {
      expect(const GroupSnapshot().canSteer, isTrue);
    });

    test('a guest may steer when guests are free', () {
      expect(_snapshot().canSteer, isTrue);
    });

    test(
      'a guest may not steer while the owner is here and guests only add',
      () {
        expect(_snapshot(guestControl: 'add').canSteer, isFalse);
      },
    );

    test('the owner always may', () {
      expect(_snapshot(guestControl: 'add', you: 'owner').canSteer, isTrue);
    });

    test('a guest may once the owner is away', () {
      expect(_snapshot(guestControl: 'add', ownerAway: true).canSteer, isTrue);
    });

    test('listening alone is not the room\'s to refuse', () {
      expect(_snapshot(guestControl: 'add', solo: true).canSteer, isTrue);
    });
  });
}
