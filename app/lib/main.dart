import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_settings.dart';
import 'data/backend.dart';
import 'data/recent_rooms.dart';
import 'data/room_controller.dart';
import 'frame_stats.dart';
import 'ui/scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  watchFrames();
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final room = RoomController(NativeBackend(), recents: recents)..start();
  runApp(
    UnisonApp(
      model: AppModel(room: room, settings: settings, recents: recents),
    ),
  );
}
