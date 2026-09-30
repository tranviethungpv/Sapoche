import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unison/app.dart';
import 'package:unison/data/app_settings.dart';
import 'package:unison/data/library_controller.dart';
import 'package:unison/data/music_controller.dart';
import 'package:unison/data/recent_rooms.dart';
import 'package:unison/data/recent_searches.dart';
import 'package:unison/data/room_controller.dart';
import 'package:unison/ui/scope.dart';

import 'fake_backend.dart';

Future<(FakeBackend, RoomController)> pumpApp(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
  Map<String, Object> prefs = const {},
}) async {
  // A tall phone-shaped window; the default 800x600 one is not what the app runs on. Test text is
  // drawn with the wide Ahem font, so it is 540 dp wide instead of the usual 360 to avoid false overflows.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'theme_mode': mode.name, ...prefs});
  final backend = FakeBackend();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  final room = RoomController(backend, recents: recents);
  final library = LibraryController(backend);
  final settings = await AppSettings.load();
  await tester.pumpWidget(
    UnisonApp(
      model: AppModel(
        room: room,
        settings: settings,
        recents: recents,
        library: library,
        searches: searches,
        music: MusicController(backend),
      ),
    ),
  );
  await room.start();
  await library.start();
  return (backend, room);
}

/// Opens the settings list and one of its topics: appearance, playback, room, storage or backup.
Future<void> openTopic(WidgetTester tester, String topic) async {
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('settings-$topic')));
  await tester.pumpAndSettle();
}
