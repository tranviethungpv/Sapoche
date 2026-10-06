import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/app.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/library_controller.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/data/recent_rooms.dart';
import 'package:sapoche/data/recent_searches.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/data/update_controller.dart';
import 'package:sapoche/ui/scope.dart';

import 'fake_backend.dart';

Future<(FakeBackend, RoomController)> pumpApp(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
  Map<String, Object> prefs = const {},

  /// The app opens on the home page; most tests are about the queue, which is on the Listen tab.
  bool listen = true,

  /// What the native side knows about this phone; by default a name was already used.
  Profile? profile,

  /// Stands in for the system's photo picker.
  PhotoPicker? photoPicker,

  /// Whether the phone can show the picture in a small window.
  bool pipSupported = true,
}) async {
  // A tall phone-shaped window; the default 800x600 one is not what the app runs on. Test text is
  // drawn with the wide Ahem font, so it is 540 dp wide instead of the usual 360 to avoid false overflows.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  // Long titles would scroll for ever, and a test could never settle; the system setting stops that
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  // The language is a global; a test that changed it must not leave it to the next one
  addTearDown(() => S.current = 'en');
  SharedPreferences.setMockInitialValues({'theme_mode': mode.name, ...prefs});
  final backend = FakeBackend();
  if (profile != null) backend.profileValue = profile;
  backend.pipSupportedValue = pipSupported;
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  final room = RoomController(backend, recents: recents);
  final library = LibraryController(backend);
  final settings = await AppSettings.load();
  await tester.pumpWidget(
    SapocheApp(
      model: AppModel(
        room: room,
        settings: settings,
        recents: recents,
        library: library,
        searches: searches,
        music: MusicController(backend),
        update: UpdateController(backend),
        photoPicker: photoPicker ?? () async => null,
      ),
    ),
  );
  await room.start();
  await library.start();
  if (listen) {
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.tabListen));
    await tester.pumpAndSettle();
  }
  return (backend, room);
}

/// Opens the settings from the gear on the home page.
Future<void> openSettingsList(WidgetTester tester) async {
  await tester.tap(find.text(S.tabHome));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(S.settingsTitle));
  await tester.pumpAndSettle();
}

/// Opens the settings and one of the topics: appearance, playback, room, storage or backup.
Future<void> openTopic(WidgetTester tester, String topic) async {
  await openSettingsList(tester);
  await tester.tap(find.byKey(ValueKey('settings-$topic')));
  await tester.pumpAndSettle();
}
