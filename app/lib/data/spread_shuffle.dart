import 'dart:math';

/// The songs of several lists as one shuffled list in which every list is spread evenly, as Spotify's shuffle does:
/// each list is mixed on its own, and its songs are then set at equal distances along the whole, with a little chance in
/// each place. A list of 300 songs and one of 20 therefore both run through to the end, the small one once every fifteen
/// songs or so, instead of the small one's songs landing in a clump; and a list cut short at some length keeps every
/// list in it in its share. With one list this is the plain shuffle.
List<T> spreadShuffle<T>(List<List<T>> lists, [Random? random]) {
  final dice = random ?? Random();
  final placed = <(double, T)>[];
  for (final list in lists) {
    final mixed = [...list]..shuffle(dice);
    for (var i = 0; i < mixed.length; i++) {
      placed.add(((i + dice.nextDouble()) / mixed.length, mixed[i]));
    }
  }
  placed.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, song) in placed) song];
}
