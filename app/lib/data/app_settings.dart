import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences that only concern how the app looks on this phone.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs) : _themeMode = _read(_prefs);

  final SharedPreferences _prefs;
  ThemeMode _themeMode;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _prefs.setString(_key, mode.name);
    notifyListeners();
  }

  static const _key = 'theme_mode';

  static ThemeMode _read(SharedPreferences prefs) =>
      ThemeMode.values.asNameMap()[prefs.getString(_key)] ?? ThemeMode.system;
}
