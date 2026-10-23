import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/spread_shuffle.dart';

void main() {
  List<String> list(String name, int n) => [
    for (var i = 0; i < n; i++) '$name$i',
  ];

  test('keeps every song once', () {
    final lists = [list('a', 30), list('b', 7), list('c', 1), <String>[]];
    final out = spreadShuffle(lists, Random(1));
    expect(out.length, 38);
    expect(out.toSet().length, 38);
  });

  test('with one list it is a plain shuffle of it', () {
    final out = spreadShuffle([list('a', 50)], Random(2));
    expect(out.toSet(), list('a', 50).toSet());
    expect(out, isNot(list('a', 50)), reason: 'it was mixed');
  });

  test('a short list is spread along the whole and not clumped', () {
    // 300 songs and 20: the small one's songs should come about every 16 places
    for (var seed = 0; seed < 30; seed++) {
      final out = spreadShuffle([list('a', 300), list('b', 20)], Random(seed));
      final at = [
        for (var i = 0; i < out.length; i++)
          if (out[i].startsWith('b')) i,
      ];
      expect(at.length, 20);
      for (var i = 1; i < at.length; i++) {
        expect(
          at[i] - at[i - 1],
          inInclusiveRange(1, 32),
          reason: 'seed $seed',
        );
      }
      expect(at.first, lessThan(32));
      expect(at.last, greaterThan(out.length - 32));
    }
  });

  test('cut short, every list keeps its share', () {
    final out = spreadShuffle([
      list('a', 600),
      list('b', 300),
      list('c', 100),
    ], Random(3)).take(200);
    int of(String p) => out.where((s) => s.startsWith(p)).length;
    expect(of('a'), inInclusiveRange(116, 124)); // 120 of 200
    expect(of('b'), inInclusiveRange(56, 64)); // 60
    expect(of('c'), inInclusiveRange(18, 22)); // 20
  });

  test('two lists of one length never run three in a row', () {
    for (var seed = 0; seed < 50; seed++) {
      final out = spreadShuffle([list('a', 40), list('b', 40)], Random(seed));
      for (var i = 2; i < out.length; i++) {
        expect(
          {out[i][0], out[i - 1][0], out[i - 2][0]}.length,
          greaterThan(1),
          reason: 'seed $seed at $i',
        );
      }
    }
  });
}
