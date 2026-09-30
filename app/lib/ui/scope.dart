import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import '../data/library_controller.dart';
import '../data/recent_rooms.dart';
import '../data/room_controller.dart';

/// The long-lived objects every screen may need.
class AppModel {
  const AppModel({
    required this.room,
    required this.settings,
    required this.recents,
    required this.library,
  });

  final RoomController room;
  final AppSettings settings;

  /// Rooms this device has been in.
  final RecentRooms recents;

  /// Liked songs and history.
  final LibraryController library;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.model, required super.child});

  final AppModel model;

  static AppModel of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.model;

  static RoomController roomOf(BuildContext context) => of(context).room;

  @override
  bool updateShouldNotify(AppScope oldWidget) => model != oldWidget.model;
}
