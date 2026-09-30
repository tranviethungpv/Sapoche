import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unison/data/recent_searches.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'the newest search is first and the same words are not listed twice',
    () async {
      final searches = await RecentSearches.load();
      searches.add('lofi');
      searches.add('jazz');
      searches.add('  LOFI  ');
      expect(searches.terms, ['LOFI', 'jazz']);
    },
  );

  test('blank searches are not kept', () async {
    final searches = await RecentSearches.load();
    searches.add('   ');
    expect(searches.terms, isEmpty);
  });

  test('only the last few are kept', () async {
    final searches = await RecentSearches.load();
    for (var i = 0; i < RecentSearches.limit + 4; i++) {
      searches.add('term $i');
    }
    expect(searches.terms, hasLength(RecentSearches.limit));
    expect(searches.terms.first, 'term ${RecentSearches.limit + 3}');
  });

  test('one can be removed, or all', () async {
    final searches = await RecentSearches.load();
    searches.add('a');
    searches.add('b');
    searches.remove('a');
    expect(searches.terms, ['b']);
    searches.clear();
    expect(searches.terms, isEmpty);
  });

  test('they come back after a restart', () async {
    final first = await RecentSearches.load();
    first.add('lofi');
    final again = await RecentSearches.load();
    expect(again.terms, ['lofi']);
  });
}
