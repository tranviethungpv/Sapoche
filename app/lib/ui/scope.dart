import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import '../data/library_controller.dart';
import '../data/music_controller.dart';
import '../data/photo_picker.dart';
import '../data/recent_rooms.dart';
import '../data/recent_searches.dart';
import '../data/room_controller.dart';
import '../data/update_controller.dart';

/// The long-lived objects every screen may need.
class AppModel {
  const AppModel({
    required this.room,
    required this.settings,
    required this.recents,
    required this.library,
    required this.searches,
    required this.music,
    required this.update,
    this.photoPicker = pickPhoto,
  });

  final RoomController room;
  final AppSettings settings;

  /// Rooms this device has been in.
  final RecentRooms recents;

  /// Liked songs and history.
  final LibraryController library;

  /// What was searched for lately.
  final RecentSearches searches;

  /// What the full player shows about a song: lyrics, related songs, the artist.
  final MusicController music;

  /// Newer versions of this app.
  final UpdateController update;

  /// Where the person's own picture comes from.
  final PhotoPicker photoPicker;
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
