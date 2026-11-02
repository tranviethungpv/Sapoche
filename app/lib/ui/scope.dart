import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import '../data/library_controller.dart';
import '../data/music_controller.dart';
import '../data/photo_picker.dart';
import '../data/photo_save.dart';
import '../data/recent_rooms.dart';
import '../data/recent_searches.dart';
import '../data/room_controller.dart';
import '../data/sticker_store.dart';
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
    required this.stickers,
    this.photoPicker = pickPhoto,
    this.wallpaperPicker = pickWallpaper,
    this.chatPhotoPicker = pickChatPhotos,
    this.photoSaver = savePhoto,
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

  /// The sticker packs and the stickers used lately.
  final StickerStore stickers;

  /// Where the person's own picture comes from.
  final PhotoPicker photoPicker;

  /// Where the photo behind a room's chat comes from.
  final WallpaperPicker wallpaperPicker;

  /// Where the photos to send in the chat come from.
  final ChatPhotoPicker chatPhotoPicker;

  /// Where a picture of the chat is saved to: the gallery, or the downloads of a browser.
  final PhotoSaver photoSaver;
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
