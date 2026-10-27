import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/taste.dart';
import 'package:sapoche/data/web/wire.dart';

// The cases of TasteTest.kt and SuggestionsTest.kt, for the Dart copy of the two

const day = 24 * 60 * 60 * 1000;
const now = 1000 * day;

TrackRef song(String id, [String? artist, int sec = 200]) =>
    TrackRef(id, 'Title $id', artist ?? 'Artist $id', null, sec * 1000);

Stamped heard(String id, [int daysAgo = 1, String? artist]) => Stamped(song(id, artist), now - daysAgo * day);

Taste taste({
  List<Stamped> heard = const [],
  List<Stamped> liked = const [],
  List<Stamped> skipped = const [],
  int Function(int)? hourOf,
}) => Taste(heard: heard, liked: liked, skipped: skipped, now: now, hourOf: hourOf ?? (_) => 12);

List<String> ids(List<TrackRef> list) => [for (final t in list) t.videoId];

void main() {
  group('taste', () {
    test('an artist is known once listened to', () {
      final t = taste(heard: [heard('a', 1, 'Jack, K-ICM')]);
      expect(t.knows('Jack'), isTrue);
      expect(t.knows('jack - Topic'), isTrue);
      expect(t.knows('Someone else'), isFalse);
    });

    test('old listens count for less than new ones', () {
      final t = taste(heard: [heard('old', 90), heard('new', 1)]);
      // Three half-lives later a listen is worth an eighth: the artist is not known any more
      expect(t.knows('Artist old'), isFalse);
      expect(t.knows('Artist new'), isTrue);
    });

    test('songs left again and again make an artist disliked', () {
      final skips = [heard('a', 1, 'Same'), heard('b', 2, 'Same')];
      expect(taste(skipped: skips).dislikes('Same'), isTrue);
      // A heard song of the artist makes up for a skip
      expect(taste(heard: [heard('c', 1, 'Same')], skipped: skips).dislikes('Same'), isFalse);
    });

    test('a like weighs more than a listen', () {
      final t = taste(heard: [heard('a'), heard('b'), heard('b', 2)], liked: [heard('a')]);
      expect(t.seeds(2), ['a', 'b'], reason: 'a: 1 listen and a like beat b: 2 listens');
    });

    test('seeds are the best loved songs, one for each artist', () {
      final listens = [
        heard('a1', 1, 'A'), heard('a1', 2, 'A'), heard('a1', 3, 'A'),
        heard('a2', 1, 'A'), heard('a2', 2, 'A'),
        heard('b1', 1, 'B'),
        heard('c1', 1, 'C'),
      ];
      expect(taste(heard: listens).seeds(3), ['a1', 'b1', 'c1']);
    });

    test('a song from a file on this device is never a seed, but still tells what is liked', () {
      final t = taste(heard: [heard('local:0123456789abcdef', 1, 'Mine'), heard('b', 2, 'Other')]);
      expect(t.seeds(5), ['b']);
      expect(t.knows('Mine'), isTrue);
    });

    test('what is played at this hour does not seed from a file on this device', () {
      final plays = [for (var i = 1; i <= 6; i++) heard('local:0123456789abcdef', i, 'Mine')];
      expect(taste(heard: plays).contextSeeds('afternoon'), isEmpty);
    });

    test('a second song of an artist fills a seed that would be empty', () {
      final listens = [heard('a1', 1, 'A'), heard('a1', 2, 'A'), heard('a2', 1, 'A'), heard('b1', 1, 'B')];
      expect(taste(heard: listens).seeds(3), ['a1', 'b1', 'a2']);
    });

    test('songs that were only skipped are not seeds, nor are blocked ones', () {
      final t = taste(heard: [heard('a'), heard('b'), heard('c')], skipped: [heard('c'), heard('c', 2)]);
      expect(t.seeds(5), ['a', 'b']);
      expect(t.seeds(5, const Blocklist(songs: {'a'})), ['b']);
      expect(t.seeds(5, const Blocklist(artists: {'artist b'})), ['a']);
    });

    test('nothing is known about someone who has not listened', () {
      final t = taste();
      expect(t.seeds(5), isEmpty);
      expect(t.knows('Anyone'), isFalse);
      expect(t.dislikes('Anyone'), isFalse);
    });

    test('the time of day is cut in four', () {
      expect(
        [4, 5, 10, 11, 16, 17, 21, 22].map(Taste.bucketOf),
        ['night', 'morning', 'morning', 'afternoon', 'afternoon', 'evening', 'evening', 'night'],
      );
    });

    test('what is played at this hour seeds the mix for it', () {
      // Each listen has a moment of its own, so the test can say which hour it was at
      Stamped at(String id, int daysAgo, int ms) => Stamped(song(id), now - daysAgo * day - ms);
      final morning = [for (var i = 1; i <= 5; i++) at('m1', i, 1000), for (var i = 1; i <= 2; i++) at('m2', i, 2000)];
      final evening = [for (var i = 1; i <= 3; i++) at('e1', i, 3000)];
      const hours = {1000: 8, 2000: 8, 3000: 20};
      final t = taste(heard: [...morning, ...evening], hourOf: (s) => hours[(now - s) % day]!);
      expect(ids(t.contextSeeds('morning')), ['m1', 'm2']);
      expect(ids(t.contextSeeds('evening')), isEmpty, reason: 'three listens do not make a habit');
      expect(t.contextSeeds('night'), isEmpty);
    });

    test('two songs of one artist are one seed for a time of day', () {
      final listens = [
        for (var i = 1; i <= 4; i++) heard('s1', i, 'Same'),
        for (var i = 1; i <= 3; i++) heard('s2', i, 'Same'),
        heard('o', 1, 'Other'),
      ];
      expect(ids(taste(heard: listens).contextSeeds('afternoon')), ['s1', 'o']);
    });

    test('an artist is a name in plain letters', () {
      expect(Taste.artistKey('Sơn Tùng M-TP'), 'sơn tùng m tp');
      expect(Taste.artistKey('Jack & K-ICM'), 'jack');
      expect(Taste.artistKey('Noo Phước Thịnh - Topic'), 'noo phước thịnh');
      expect(Taste.artistLabel('Jack, K-ICM'), 'Jack');
    });

    test('an artist credit is split at "và" and "x" but not inside a name', () {
      expect(Taste.artistKey('Hà và Nam'), 'hà');
      expect(Taste.artistKey('Alex'), 'alex');
      expect(Taste.artistKey('Andy and Bo'), 'andy');
      expect(Taste.artistKey('Soobin x Hoàng'), 'soobin');
    });
  });

  group('suggestions', () {
    TrackRef track(String id, [int sec = 200]) => TrackRef(id, 'Title $id', 'Artist', null, sec * 1000);
    TrackRef by(String id, String artist) => TrackRef(id, 'Title $id', artist, null, 200000);
    Taste tasteOf(List<String> known) =>
        Taste(heard: [for (var i = 0; i < known.length; i++) Stamped(by('k$i', known[i]), now - 1000)], liked: const [], skipped: const [], now: now);

    test('seeds take turns', () {
      final mixed = Suggestions.mix([
        [track('a1'), track('a2'), track('a3')],
        [track('b1'), track('b2')],
        [track('c1')],
      ], {}, 10);
      expect(ids(mixed), ['a1', 'b1', 'c1', 'a2', 'b2', 'a3']);
    });

    test('hour long mixes and clips are not songs', () {
      final mixed = Suggestions.mix([
        [track('mix', 3600), track('clip', 20), track('ok'), track('edge', 600), track('short', 60)],
      ], {}, 10);
      expect(ids(mixed), ['ok', 'edge', 'short']);
    });

    test('songs already known are left out', () {
      final mixed = Suggestions.mix([
        [track('a'), track('b'), track('c')],
      ], {'a', 'c'}, 10);
      expect(ids(mixed), ['b']);
    });

    test('a song two seeds agree on comes once', () {
      final mixed = Suggestions.mix([
        [track('x'), track('a')],
        [track('x'), track('b')],
      ], {}, 10);
      expect(ids(mixed), ['x', 'b', 'a'], reason: 'the second seed skips the repeat and gives its next song');
    });

    test('it stops at the limit', () {
      final mixed = Suggestions.mix([
        [track('a'), track('b')],
        [track('c'), track('d')],
      ], {}, 3);
      expect(ids(mixed), ['a', 'c', 'b']);
    });

    test('a seed that has nothing does not hold up the others', () {
      final mixed = Suggestions.mix([
        const [],
        [track('a'), track('b')],
      ], {}, 10);
      expect(ids(mixed), ['a', 'b']);
    });

    test('nothing in, nothing out', () {
      expect(Suggestions.mix(const [], {}, 5), isEmpty);
      expect(Suggestions.mix([[track('a')]], {}, 0), isEmpty);
    });

    test('what the mix is told to refuse stays out', () {
      final mixed = Suggestions.mix([
        [track('a'), track('b'), track('c')],
      ], {}, 10, (t) => t.videoId != 'b');
      expect(ids(mixed), ['a', 'c']);
    });

    test('mostly artists the person knows, with new ones in between', () {
      final known = [for (var i = 1; i <= 9; i++) by('k$i', 'Known $i')];
      final fresh = [for (var i = 1; i <= 9; i++) by('f$i', 'Fresh $i')];
      final t = tasteOf([for (var i = 1; i <= 9; i++) 'Known $i']);
      final mixed = Suggestions.compose([[...known, ...fresh]], t, const Blocklist(), {}, 10);
      // Three of ten come from artists the person does not know, at the third, sixth and ninth place
      expect(ids(mixed), ['k1', 'k2', 'f1', 'k3', 'k4', 'f2', 'k5', 'k6', 'f3', 'k7']);
    });

    test('when one kind runs out the other fills the list', () {
      final t = tasteOf(['Known']);
      final onlyFresh = Suggestions.compose([
        [by('f1', 'A'), by('f2', 'B'), by('f3', 'C')],
      ], t, const Blocklist(), {}, 10);
      expect(ids(onlyFresh), ['f1', 'f2', 'f3']);
      final onlyKnown = Suggestions.compose([
        [by('k1', 'Known'), by('k2', 'Known'), by('k3', 'Known')],
      ], t, const Blocklist(), {}, 10);
      expect(ids(onlyKnown), ['k1', 'k2'], reason: 'and no artist comes more than twice');
    });

    test('blocked and disliked artists are never offered', () {
      final skipped = [Stamped(by('s1', 'Disliked'), now - 1000), Stamped(by('s2', 'Disliked'), now - 2000)];
      final t = Taste(heard: const [], liked: const [], skipped: skipped, now: now);
      final lists = [
        [by('a', 'Disliked'), by('b', 'Blocked'), by('c', 'Fine'), by('d', 'Fine 2')],
      ];
      final mixed = Suggestions.compose(lists, t, const Blocklist(artists: {'blocked'}), {'d'}, 10);
      expect(ids(mixed), ['c']);
    });

    test('discover offers one song of each artist that is new', () {
      final t = tasteOf(['Known']);
      final lists = [
        [by('k1', 'Known'), by('n1', 'New'), by('n2', 'New'), by('m1', 'More')],
        [by('o1', 'Other'), by('n3', 'New')],
      ];
      expect(ids(Suggestions.discover(lists, t, const Blocklist(), {}, 10)), ['n1', 'o1', 'm1']);
      expect(ids(Suggestions.discover(lists, t, const Blocklist(), {}, 1)), ['n1']);
    });
  });
}
