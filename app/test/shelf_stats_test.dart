import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/shelf_stats.dart';

Future<ShelfStats> load([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return ShelfStats(await SharedPreferences.getInstance());
}

void main() {
  const rows = ['quick', 'again', 'discover', 'charts'];

  /// How often each row comes first over many draws.
  Map<String, int> firsts(ShelfStats stats, String part, {int draws = 400}) {
    final rng = Random(7);
    final wins = {for (final r in rows) r: 0};
    for (var i = 0; i < draws; i++) {
      final first = stats.order(rows, part, random: rng).first;
      wins[first] = wins[first]! + 1;
    }
    return wins;
  }

  test(
    'a new person sees the order the page was made in, most of the time',
    () async {
      final wins = firsts(await load(), 'morning');
      expect(wins['quick'], greaterThan(wins['charts']!));
      expect(
        wins.values.every((n) => n > 0),
        isTrue,
        reason: 'but every row gets its turn at the top',
      );
    },
  );

  test(
    'a row that is touched rises, and one that is only shown sinks',
    () async {
      final stats = await load();
      for (var i = 0; i < 40; i++) {
        stats.shown('evening', rows);
        if (i % 2 == 0) stats.touched('evening', 'charts');
      }
      final wins = firsts(stats, 'evening');
      expect(wins['charts'], greaterThan(300), reason: '$wins');
      expect(wins['quick'], lessThan(50), reason: '$wins');
    },
  );

  test('the parts of the day are kept apart', () async {
    final stats = await load();
    for (var i = 0; i < 40; i++) {
      stats.shown('night', rows);
      stats.touched('night', 'discover');
    }
    expect(firsts(stats, 'night')['discover'], greaterThan(300));
    final morning = firsts(stats, 'morning');
    expect(morning['discover'], lessThan(morning['quick']!));
  });

  test('a row cannot be touched more often than it was shown', () async {
    final stats = await load();
    stats.touched('night', 'quick');
    expect(stats.of('night', 'quick'), (0, 0));
    stats.shown('night', ['quick']);
    stats.touched('night', 'quick');
    stats.touched('night', 'quick');
    expect(stats.of('night', 'quick'), (1, 1));
  });

  test('what is known is kept for the next time the app opens', () async {
    final stats = await load();
    stats.shown('night', ['quick', 'again']);
    stats.touched('night', 'again');
    final prefs = await SharedPreferences.getInstance();
    final again = ShelfStats(prefs);
    expect(again.of('night', 'again'), (1, 1));
    expect(again.of('night', 'quick'), (1, 0));
  });

  test('old habits fade: the counts are halved after many showings', () async {
    final stats = await load();
    for (var i = 0; i < 399; i++) {
      stats.shown('night', ['quick']);
      if (i < 200) stats.touched('night', 'quick');
    }
    expect(stats.of('night', 'quick'), (399, 200));
    stats.shown('night', ['quick']);
    final (shown, touched) = stats.of('night', 'quick');
    expect(shown, 200);
    expect(touched, 100);
  });

  test('a stored value that cannot be read is no reason to fail', () async {
    for (final broken in [
      '',
      'not json',
      '[]',
      '{"a":1}',
      '{"a":{"b":["x"]}}',
    ]) {
      final stats = await load({'shelf_stats': broken});
      expect(stats.order(rows, 'night').toSet(), rows.toSet(), reason: broken);
    }
  });

  test(
    'a fixed random gives a fixed order, and every row is in it once',
    () async {
      final stats = await load();
      final a = stats.order(rows, 'night', random: Random(3));
      final b = stats.order(rows, 'night', random: Random(3));
      expect(a, b);
      expect(a.toSet(), rows.toSet());
      expect(a.length, rows.length);
    },
  );
}
