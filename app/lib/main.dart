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
import 'frame_stats.dart';
import 'ui/scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  watchFrames();
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  final backend = NativeBackend();
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
