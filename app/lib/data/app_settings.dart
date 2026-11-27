import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calm.dart';
import 'shelf_stats.dart';
import 'tv_mode.dart';

export 'calm.dart' show EffectsLevel;
export 'tv_mode.dart' show TvMode;

/// How the full player is drawn: the one Sapoche began with, or one laid out like the players of two other music apps.
/// The app names them without a brand (`S.playerStyleCards`, `S.playerStyleFullCover`).
enum PlayerStyle {
  classic,
  spotify,
  appleMusic;

  /// The style of a phone that has not chosen: the full cover.
  static const defaultStyle = appleMusic;
}

/// Preferences that only concern how the app looks on this phone.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, Random? shelfRandom)
    : _themeMode = _read(_prefs),
      _language = _prefs.getString(_languageKey),
      _avatar = _readAvatar(_prefs),
      shelves = ShelfStats(_prefs, random: shelfRandom) {
    Calm.chosen = _readEffects(_prefs);
    Tv.mode = tvMode;
  }

  final SharedPreferences _prefs;

  /// Which rows of the home page the person touches, and so the order to show them in.
  final ShelfStats shelves;
  ThemeMode _themeMode;
  String? _language;
  Uint8List? _avatar;

  /// [shelfRandom] draws the order of the rows of the home page; a test gives it one that always draws the same.
  static Future<AppSettings> load({Random? shelfRandom}) async =>
      AppSettings._(await SharedPreferences.getInstance(), shelfRandom);

  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _prefs.setString(_key, mode.name);
    notifyListeners();
  }

  /// How the full player is drawn on this phone. Not in the backup: it is a look, like the theme. It has a notifier of
  /// its own and does not wake [AppSettings]'s listeners: the whole app listens to those (the theme, the language), and
  /// a change that only the player and one list of Settings care about would build all of it again.
  PlayerStyle get playerStyle => playerStyleListenable.value;

  late final ValueNotifier<PlayerStyle> playerStyleListenable = ValueNotifier(
    PlayerStyle.values.asNameMap()[_prefs.getString(_playerStyleKey)] ??
        PlayerStyle.defaultStyle,
  );

  set playerStyle(PlayerStyle style) {
    if (style == playerStyle) return;
    _prefs.setString(_playerStyleKey, style.name);
    playerStyleListenable.value = style;
  }

  /// The colour the person picked for the app; null keeps the pink it was designed in.
  Color? get accent {
    final value = _prefs.getInt(_accentKey);
    return value == null ? null : Color(value);
  }

  set accent(Color? color) {
    if (color == accent) return;
    if (color == null) {
      _prefs.remove(_accentKey);
    } else {
      _prefs.setInt(_accentKey, color.toARGB32());
    }
    notifyListeners();
  }

  /// When the sheet about [version] last came up; null if it never has.
  DateTime? updateSheetShown(String version) {
    final millis = _prefs.getInt('$_updateSheetKey$version');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  void updateSheetWasShown(String version, DateTime at) =>
      _prefs.setInt('$_updateSheetKey$version', at.millisecondsSinceEpoch);

  /// Which effects level the person picked in Settings; null while they have not chosen, when the phone's own
  /// capability decides ([Calm.level] is what is in force).
  EffectsLevel? get effects => _readEffects(_prefs);

  set effects(EffectsLevel? value) {
    if (value == null) {
      _prefs.remove(_effectsKey);
      _prefs.remove(_lightEffectsKey);
    } else {
      _prefs.setString(_effectsKey, value.name);
      _prefs.remove(_lightEffectsKey);
    }
    Calm.chosen = value;
    notifyListeners();
  }

  /// Whether the app draws for a TV: the device's own word, or the person's.
  TvMode get tvMode =>
      TvMode.values.asNameMap()[_prefs.getString(_tvModeKey)] ?? TvMode.auto;

  set tvMode(TvMode value) {
    if (value == tvMode) return;
    _prefs.setString(_tvModeKey, value.name);
    Tv.mode = value;
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

  /// When the person last answered "not now" to the offer of notices of the chat; null if they never did.
  DateTime? get noticeOfferedAt {
    final ms = _prefs.getInt(_noticeOfferedKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set noticeOfferedAt(DateTime? at) {
    if (at == null) {
      _prefs.remove(_noticeOfferedKey);
    } else {
      _prefs.setInt(_noticeOfferedKey, at.millisecondsSinceEpoch);
    }
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
  static const _noticeOfferedKey = 'noticeOfferedAt';
  static const _key = 'theme_mode';
  static const _languageKey = 'language';
  static const _effectsKey = 'effects';
  static const _lightEffectsKey = 'light_effects';
  static const _accentKey = 'accent';
  static const _playerStyleKey = 'player_style';
  static const _tvModeKey = 'tv_mode';
  static const _updateSheetKey = 'update_sheet_';

  static ThemeMode _read(SharedPreferences prefs) =>
      ThemeMode.values.asNameMap()[prefs.getString(_key)] ?? ThemeMode.system;

  static EffectsLevel? _readEffects(SharedPreferences prefs) {
    final saved = EffectsLevel.values.asNameMap()[prefs.getString(_effectsKey)];
    if (saved != null) return saved;
    final legacy = prefs.getBool(_lightEffectsKey);
    if (legacy == null) return null;
    return legacy ? EffectsLevel.light : EffectsLevel.full;
  }
}
