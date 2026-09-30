import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What was searched for lately, newest first, so it can be searched again with a tap.
class RecentSearches extends ChangeNotifier {
  RecentSearches._(this._prefs)
    : _terms = _prefs.getStringList(_key) ?? const [];

  final SharedPreferences _prefs;
  List<String> _terms;

  static const _key = 'recent_searches';
  static const limit = 8;

  static Future<RecentSearches> load() async =>
      RecentSearches._(await SharedPreferences.getInstance());

  List<String> get terms => List.unmodifiable(_terms);

  /// Puts [term] on top. The same words in another case are one search.
  void add(String term) {
    final clean = term.trim();
    if (clean.isEmpty) return;
    _terms = [
      clean,
      ..._terms.where((t) => t.toLowerCase() != clean.toLowerCase()),
    ].take(limit).toList();
    _save();
  }

  void remove(String term) {
    final kept = _terms.where((t) => t != term).toList();
    if (kept.length == _terms.length) return;
    _terms = kept;
    _save();
  }

  void clear() {
    if (_terms.isEmpty) return;
    _terms = const [];
    _save();
  }

  void _save() {
    _prefs.setStringList(_key, _terms);
    notifyListeners();
  }
}
