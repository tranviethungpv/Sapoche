import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences that only concern how the app looks on this phone.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs)
    : _themeMode = _read(_prefs),
      _language = _prefs.getString(_languageKey),
      _avatar = _readAvatar(_prefs);

  final SharedPreferences _prefs;
  ThemeMode _themeMode;
  String? _language;
  Uint8List? _avatar;

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

  /// The person's own picture, shown on this phone only; null while they have not chosen one.
  Uint8List? get avatar => _avatar;

  set avatar(Uint8List? bytes) {
    _avatar = bytes;
    if (bytes == null) {
      _prefs.remove(_avatarKey);
    } else {
      _prefs.setString(_avatarKey, base64Encode(bytes));
    }
    notifyListeners();
  }

  static Uint8List? _readAvatar(SharedPreferences prefs) {
    final text = prefs.getString(_avatarKey);
    if (text == null) return null;
    try {
      return base64Decode(text);
    } on FormatException {
      return null;
    }
  }

  static const _avatarKey = 'avatar';
  static const _key = 'theme_mode';
  static const _languageKey = 'language';

  static ThemeMode _read(SharedPreferences prefs) =>
      ThemeMode.values.asNameMap()[prefs.getString(_key)] ?? ThemeMode.system;
}
