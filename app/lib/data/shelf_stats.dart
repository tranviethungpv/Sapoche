import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Which rows of the home page the person touches, kept apart for each part of the day, and from that the order to
/// show the rows in.
///
/// It is a bandit, like the one Spotify uses to rank the rows of its home page, but on this phone and about this
/// person only. Each row has been shown some times and touched some of them; the chance it is touched is guessed
/// as a Beta distribution, and the order is made by drawing a number from the guess of each row and sorting by it
/// (Thompson sampling). A row nothing is known of is drawn from a wide guess, so it gets its turn at the top; a row
/// that is touched often comes to the top and stays; one that is shown again and again without a touch sinks. The
/// order the rows come in to begin with leans the guess a little, so a new person sees the order the page was made
/// in until their own habit says otherwise.
class ShelfStats {
  ShelfStats(this._prefs, {this.random}) : _counts = _read(_prefs);

  final SharedPreferences _prefs;

  /// Draws the order when [order] is not given a random; by default a fresh one each time. A test gives it one that
  /// always draws the same.
  final Random? random;

  /// For each part of the day, for each row: how many times it was shown and how many times it was touched.
  final Map<String, Map<String, List<int>>> _counts;

  static const _key = 'shelf_stats';

  /// Counts are halved when a row has been shown this many times, so that old habits fade.
  static const _forgetAt = 400;

  /// How many times the row was shown and touched in a part of the day.
  (int shown, int touched) of(String part, String shelf) {
    final c = _counts[part]?[shelf];
    return c == null ? (0, 0) : (c[0], c[1]);
  }

  /// The rows in [shelves] were shown.
  void shown(String part, Iterable<String> shelves) {
    final counts = _counts.putIfAbsent(part, () => {});
    for (final shelf in shelves) {
      final c = counts.putIfAbsent(shelf, () => [0, 0]);
      c[0]++;
      if (c[0] >= _forgetAt) {
        c[0] = (c[0] / 2).round();
        c[1] = (c[1] / 2).round();
      }
    }
    _save();
  }

  /// Something in [shelf] was touched.
  void touched(String part, String shelf) {
    final c = _counts
        .putIfAbsent(part, () => {})
        .putIfAbsent(shelf, () => [0, 0]);
    // A row can only be touched when it was shown
    if (c[1] < c[0]) c[1]++;
    _save();
  }

  /// [shelves] in the order to show them, drawn afresh from what is known; the order they are given in is the one
  /// the page was made in. A fixed [random] gives a fixed order.
  List<String> order(List<String> shelves, String part, {Random? random}) {
    final rng = random ?? this.random ?? Random();
    final n = shelves.length;
    final drawn = <String, double>{};
    for (final (i, shelf) in shelves.indexed) {
      final (shown, touched) = of(part, shelf);
      // The place a row has by default leans the guess: as if it had been touched a few times already
      final alpha = 1 + touched + (n - 1 - i) * 0.5;
      final beta = 3.0 + (shown - touched);
      drawn[shelf] = _beta(alpha, beta, rng);
    }
    return [...shelves]..sort((a, b) => drawn[b]!.compareTo(drawn[a]!));
  }

  /// A draw from Beta([alpha], [beta]) by the normal approximation, which is close enough for sorting rows.
  static double _beta(double alpha, double beta, Random rng) {
    final total = alpha + beta;
    final mean = alpha / total;
    final spread = sqrt(alpha * beta / (total * total * (total + 1)));
    // Box-Muller
    final u = 1 - rng.nextDouble();
    final v = rng.nextDouble();
    final normal = sqrt(-2 * log(u)) * cos(2 * pi * v);
    return (mean + spread * normal).clamp(0.0, 1.0);
  }

  void _save() {
    _prefs.setString(
      _key,
      jsonEncode({
        for (final part in _counts.entries)
          part.key: {for (final s in part.value.entries) s.key: s.value},
      }),
    );
  }

  static Map<String, Map<String, List<int>>> _read(SharedPreferences prefs) {
    try {
      final decoded = jsonDecode(prefs.getString(_key) ?? '{}');
      return {
        for (final part in (decoded as Map).entries)
          part.key as String: {
            for (final s in (part.value as Map).entries)
              s.key as String: [
                for (final n in s.value as List) (n as num).toInt(),
              ].take(2).toList(),
          },
      };
    } on Object {
      return {};
    }
  }
}
