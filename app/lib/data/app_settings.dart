import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences that only concern how the app looks on this phone.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs)
    : _themeMode = _read(_prefs),
      _language = _prefs.getString(_languageKey);

  final SharedPreferences _prefs;
  ThemeMode _themeMode;
  String? _language;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _prefs.setString(_key, mode.name);
    notifyListeners();
  }

  /// The language the person picked, one of `S.languages`; null follows the phone's language.
  String? get language => _language;

  set language(String? code) {
    if (code == _language) return;
    _language = code;
    if (code == null) {
      _prefs.remove(_languageKey);
    } else {
      _prefs.setString(_languageKey, code);
    }
    notifyListeners();
  }

  static const _key = 'theme_mode';
  static const _languageKey = 'language';

  static ThemeMode _read(SharedPreferences prefs) =>
      ThemeMode.values.asNameMap()[prefs.getString(_key)] ?? ThemeMode.system;
}
