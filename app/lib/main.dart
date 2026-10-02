import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_settings.dart';
import 'data/backend.dart';
import 'data/library_controller.dart';
import 'data/music_controller.dart';
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
  final Backend backend = NativeBackend();
  // Where there is no cable to read the frame statistics from, they go into the log of the app
  watchFrames(report: backend.note);
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  // The display runs at its fastest only while something moves
  FrameBoost((on) => backend.setSmooth(on)).start();
  final room = RoomController(backend, recents: recents)..start();
  // The native side keeps the picture too, but it is the person's choice that counts when the app opens
  room.shareAvatar(settings.avatar);
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
