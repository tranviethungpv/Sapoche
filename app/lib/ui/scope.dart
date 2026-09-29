import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import '../data/room_controller.dart';

/// The two long-lived objects every screen may need.
class AppModel {
  const AppModel({required this.room, required this.settings});

  final RoomController room;
  final AppSettings settings;
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
