import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_settings.dart';
import 'data/backend.dart';
import 'data/library_controller.dart';
import 'data/music_controller.dart';
import 'data/preview_backend.dart';
import 'data/recent_rooms.dart';
import 'data/recent_searches.dart';
import 'data/room_controller.dart';
import 'data/update_controller.dart';
import 'frame_boost.dart';
import 'frame_stats.dart';
import 'ui/scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter keeps up to 100 MB of decoded pictures; covers are small and a phone has better uses for the memory
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;
  watchFrames();
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  // iOS has no native side yet; it opens the screens on a stand-in
  final Backend backend = Platform.isIOS ? PreviewBackend() : NativeBackend();
  // The display runs at its fastest only while something moves
  FrameBoost((on) => backend.setSmooth(on)).start();
  final room = RoomController(backend, recents: recents)..start();
  final library = LibraryController(backend)..start();
  runApp(
    UnisonApp(
      model: AppModel(
        room: room,
        settings: settings,
        recents: recents,
        library: library,
        searches: searches,
        music: MusicController(backend),
        update: UpdateController(backend),
      ),
    ),
  );
}
