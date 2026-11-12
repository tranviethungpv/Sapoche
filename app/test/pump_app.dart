import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/app.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/library_controller.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/data/photo_save.dart';
import 'package:sapoche/data/recent_rooms.dart';
import 'package:sapoche/data/recent_searches.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/data/sticker_store.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/data/update_controller.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';

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

  /// Stands in for the picker of the photo behind a chat.
  WallpaperPicker? wallpaperPicker,

  /// Stands in for the picker of the photos to send in the chat.
  ChatPhotoPicker? chatPhotoPicker,

  /// Stands in for saving a picture to the gallery.
  PhotoSaver? photoSaver,

  /// Stands in for the picker of the video to send in the chat.
  ChatVideoPicker? chatVideoPicker,

  /// Stands in for the clipboard: by default there are no pictures on it.
  ClipboardCheck? clipboardHasPhotos,
  ClipboardReader? clipboardPhotos,

  /// The sticker packs; by default a server that has none, so that no test reaches for the network.
  StickerStore? stickers,

  /// Whether the phone can show the picture in a small window.
  bool pipSupported = true,

  /// Sets up what the native side knows before the app is built: the home page asks for some of it as it is drawn.
  void Function(FakeBackend backend)? prepare,
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
  prepare?.call(backend);
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  final room = RoomController(backend, recents: recents);
  final library = LibraryController(backend, quiet: Duration.zero);
  final settings = await AppSettings.load(shelfRandom: SteadyRandom());
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
        stickers:
            stickers ??
            StickerStore(
              prefs: await SharedPreferences.getInstance(),
              server: () => 'https://stickers.test',
              client: MockClient((_) async => http.Response('', 404)),
            ),
        photoPicker: photoPicker ?? () async => null,
        wallpaperPicker: wallpaperPicker ?? () async => null,
        chatPhotoPicker: chatPhotoPicker ?? (_) async => const [],
        chatVideoPicker: chatVideoPicker ?? (_) async => null,
        clipboardHasPhotos: clipboardHasPhotos ?? noPhotosOnClipboard,
        clipboardPhotos: clipboardPhotos ?? readNoClipboardPhotos,
        photoSaver: photoSaver ?? (_, _, _) async => PhotoSaveResult.saved,
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
  // The gear at the top of Home, or in a wide window the row of the sidebar that it gave way to
  final gear = find.byTooltip(S.settingsTitle);
  await tester.tap(gear.evaluate().isNotEmpty ? gear : find.text(S.settingsTitle).last);
  await tester.pumpAndSettle();
}

/// Opens the settings and one of the topics: appearance, playback, room, storage or backup.
Future<void> openTopic(WidgetTester tester, String topic) async {
  await openSettingsList(tester);
  await tester.tap(find.byKey(ValueKey('settings-$topic')));
  await tester.pumpAndSettle();
}

/// A "random" that always draws the lowest number, so that the rows of the home page keep the order they were made in.
class SteadyRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

/// Opens the full player the way a person does: from the card of the song on the Room tab while it is in view and the mini
/// player has given way to it, otherwise from the mini player.
Future<void> tapMiniPlayer(WidgetTester tester) async {
  final card = find.byKey(const ValueKey('room-now-card')).hitTestable();
  await tester.tap(card.evaluate().isNotEmpty ? card : find.byType(MiniPlayer));
}

/// Goes to the Home tab, where the mini player is always in its place, and lets the page fade in.
Future<void> goHome(WidgetTester tester) async {
  await tester.tap(find.text(S.tabHome));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}
