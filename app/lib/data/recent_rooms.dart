import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A room this device has been in, remembered so it can be joined again without typing its code.
class RecentRoom {
  const RecentRoom({required this.code, this.name, required this.lastAt});

  final String code;

  /// The room's name when it has one.
  final String? name;
  final DateTime lastAt;

  /// What to call it in a list.
  String get title => name ?? code;

  Map<String, Object?> toJson() => {
    'code': code,
    'name': name,
    'at': lastAt.millisecondsSinceEpoch,
  };

  static RecentRoom? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = json['code'];
    final at = json['at'];
    if (code is! String || at is! int) return null;
    return RecentRoom(
      code: code,
      name: json['name'] as String?,
      lastAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// The last few rooms, newest first. A room is put on top whenever this device is in it, so being sent
/// back in by a restart counts too.
class RecentRooms extends ChangeNotifier {
  RecentRooms._(this._prefs) : _rooms = _read(_prefs);

  final SharedPreferences _prefs;
  List<RecentRoom> _rooms;

  static const _key = 'recent_rooms';
  static const limit = 8;

  /// A room already on top is only written again when this much time has passed, so being in a
  /// room for hours does not rewrite the list on every message.
  static const _refreshAfter = Duration(minutes: 10);

  static Future<RecentRooms> load() async =>
      RecentRooms._(await SharedPreferences.getInstance());

  List<RecentRoom> get rooms => List.unmodifiable(_rooms);

  /// Records that this device is in room [code] now.
  void touch(String code, {String? name, DateTime? now}) {
    final at = now ?? DateTime.now();
    final top = _rooms.isEmpty ? null : _rooms.first;
    if (top != null &&
        top.code == code &&
        top.name == name &&
        at.difference(top.lastAt) < _refreshAfter) {
      return;
    }
    _rooms = [
      RecentRoom(code: code, name: name, lastAt: at),
      ..._rooms.where((r) => r.code != code),
    ].take(limit).toList();
    _save();
  }

  void forget(String code) {
    final kept = _rooms.where((r) => r.code != code).toList();
    if (kept.length == _rooms.length) return;
    _rooms = kept;
    _save();
  }

  void _save() {
    _prefs.setString(_key, jsonEncode([for (final r in _rooms) r.toJson()]));
    notifyListeners();
  }

  static List<RecentRoom> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List<Object?>)
          ?RecentRoom.fromJson(e),
      ];
    } on FormatException {
      return [];
    }
  }
}
