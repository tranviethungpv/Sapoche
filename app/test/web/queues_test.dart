import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/queues.dart';

// The cases of QueuesTest.kt for the seeds of a room's autoplay

QueueEntry by(String id, String member, {bool auto = false}) =>
    QueueEntry(id: 'item-$id', videoId: id, title: 'Title $id', artist: 'Artist', durMs: 200000, addedBy: member, auto: auto);

void main() {
  test('a room where one member added everything is asked about the last song alone', () {
    expect(Queues.seeds([by('a', 'm1'), by('b', 'm1'), by('c', 'm1')], 'c'), ['c']);
  });

  test('each member who has a song in the queue gives one seed, the latest first, up to three', () {
    final queue = [by('a', 'm1'), by('b', 'm2'), by('c', 'm3'), by('d', 'm4'), by('e', 'm1')];
    // The last song is m1's; then m4's d, m3's c; m2's b is past the limit
    expect(Queues.seeds(queue, 'e'), ['e', 'd', 'c']);
    expect(Queues.seeds(queue, 'e', max: 2), ['e', 'd']);
  });

  test("songs autoplay added are nobody's choice, and a member counts once", () {
    final queue = [by('a', 'm1'), by('b', 'm2'), by('x', 'm3', auto: true), by('c', 'm2'), by('y', 'm1', auto: true)];
    // The last song is autoplay's, so m1 and m2 are both still to be heard: m2's latest is c, then m1's a
    expect(Queues.seeds(queue, 'y'), ['y', 'c', 'a']);
  });

  test('the song asked about is always there, even when it left the queue', () {
    expect(Queues.seeds([by('a', 'm1'), by('b', 'm2')], 'gone'), ['gone', 'b', 'a']);
  });

  test('an empty queue gives the song asked about', () {
    expect(Queues.seeds(const [], 'z'), ['z']);
  });

  test("a song of each member's offer joins the seeds, going round with the epoch", () {
    final offers = [
      ['a1', 'a2', 'a3'],
      ['b1', 'b2'],
      <String>[],
      ['c1'],
    ];
    // The first song of each, from the first member; the one who offered nothing is not there
    expect(Queues.blend(['x'], offers, 0), ['x', 'a1', 'b1', 'c1']);
    // Next time the room runs out it is the second song of those who gave more than one, and the members start elsewhere
    expect(Queues.blend(['x'], offers, 1), ['x', 'b2', 'c1', 'a2']);
  });

  test('no more than five radios are asked for, and a song already a seed is not taken twice', () {
    final four = [
      ['a'],
      ['b'],
      ['c'],
      ['d'],
    ];
    expect(Queues.blend(['x', 'y', 'z'], four, 0), ['x', 'y', 'z', 'a', 'b']);
    expect(Queues.blend(['x', 'y', 'z'], four, 1), ['x', 'y', 'z', 'b', 'c']);
    expect(Queues.blend(['a'], [['a', 'b']], 0), ['a', 'b']);
    expect(Queues.blend(['x'], const [], 7), ['x']);
  });
}
