import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import '../data/comments.dart';
import '../data/connect/connect_controller.dart';
import '../data/library_controller.dart';
import '../data/music_controller.dart';
import '../data/photo_picker.dart';
import '../data/photo_save.dart';
import '../data/recent_rooms.dart';
import '../data/recent_searches.dart';
import '../data/room_controller.dart';
import '../data/sticker_store.dart';
import '../data/sync/sync_controller.dart';
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
    required this.comments,
    required this.update,
    required this.stickers,
    this.sync,
    this.connect,
    this.photoPicker = pickPhoto,
    this.wallpaperPicker = pickWallpaper,
    this.chatPhotoPicker = pickChatPhotos,
    this.chatVideoPicker = pickChatVideo,
    this.clipboardHasPhotos = noPhotosOnClipboard,
    this.clipboardPhotos = readNoClipboardPhotos,
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

  /// What people wrote under the song on YouTube, read when the full player's panel for it is opened.
  final CommentsController comments;

  /// Newer versions of this app.
  final UpdateController update;

  /// The sticker packs and the stickers used lately.
  final StickerStore stickers;

  /// Keeps the library on the server and alike on every device; null where there is none (the tests).
  final SyncController? sync;

  /// The devices of the person, one of which plays; null where there is none (the tests).
  final ConnectController? connect;

  /// Where the person's own picture comes from.
  final PhotoPicker photoPicker;

  /// Where the photo behind a room's chat comes from.
  final WallpaperPicker wallpaperPicker;

  /// Where the photos to send in the chat come from.
  final ChatPhotoPicker chatPhotoPicker;

  /// Where the video to send in the chat comes from.
  final ChatVideoPicker chatVideoPicker;

  /// Whether the clipboard holds a picture, for the chat to offer to paste it.
  final ClipboardCheck clipboardHasPhotos;

  /// The pictures on the clipboard, to be sent in the chat.
  final ClipboardReader clipboardPhotos;

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
