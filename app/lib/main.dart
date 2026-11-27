import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app.dart';
import 'data/app_settings.dart';
import 'data/backend.dart';
import 'data/backend_factory.dart';
import 'data/calm.dart';
import 'data/comments.dart';
import 'data/connect/connect_backend.dart';
import 'data/connect/connect_controller.dart';
import 'data/connect/connect_wire.dart';
import 'data/error_log.dart';
import 'data/library_controller.dart';
import 'data/models.dart' show Profile;
import 'data/music_controller.dart';
import 'data/recent_rooms.dart';
import 'data/recent_searches.dart';
import 'data/room_controller.dart';
import 'data/sticker_licenses.dart';
import 'data/sticker_store.dart';
import 'data/sync/sync_controller.dart';
import 'data/sync/sync_ports.dart';
import 'data/tv_mode.dart';
import 'data/update_controller.dart';
import 'frame_boost.dart';
import 'frame_stats.dart';
import 'ui/scope.dart';
import 'ui/widgets/cached_cover.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter keeps up to 100 MB of decoded pictures; covers are small and a phone has better uses for the memory
  // (half of that where the effects are lightened: a weak phone has the least memory to spare)
  void sizeImageCache() =>
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          (Calm.light.value ? 24 : 48) << 20;
  sizeImageCache();
  Calm.light.addListener(sizeImageCache);
  final Backend backend = await createBackend();
  // A widget that throws in a release build leaves nothing behind; this puts it in the log of the app
  ErrorLog(backend.note).install();
  // Before the first cover is asked for; without the folder the covers are only fetched
  CoverFiles.useFolder(
    await backend.cacheFolder().catchError((Object _) => null),
  );
  // The pictures inside music files on this phone are read by the native side
  CoverFiles.localCover = (id) => backend.localCover(id).catchError((Object _) => null);
  // Where there is no cable to read the frame statistics from, they go into the log of the app
  watchFrames(report: backend.note);
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  // The display runs at its fastest only while someone moves the screen
  FrameBoost(backend.setDisplayPace).start();
  // What this device is called in the lists of the person's devices until it is given a name: its model tells two phones apart
  final model = (await backend.profile().catchError((Object _) => const Profile())).device;
  late final RoomController room;
  final sync = createSyncController(
    backend: backend,
    server: () => room.profile.server,
    deviceLabel: _deviceLabel,
  );
  // The devices of the person: the screens steer the one that plays, which may be another, through this backend
  final connect = ConnectController(
    inner: backend,
    syncChanges: sync,
    syncKey: () => sync.key,
    server: () async => Uri.tryParse((await backend.profile()).server),
    serverKey: backend.serverKey,
    store: const PrefsConnectStore(),
    kind: _deviceKind,
    defaultName: () => kIsWeb || Tv.on.value || model.isEmpty ? _deviceLabel() : model,
    appVersion: (await PackageInfo.fromPlatform()).version,
  );
  // Before the room controller listens: what its backend says goes through the controller of the devices
  await connect.start();
  room = RoomController(ConnectBackend(backend, connect), recents: recents)..start();
  // The native side keeps the picture too, but it is the person's choice that counts when the app opens
  room.shareAvatar(settings.avatar);
  final library = LibraryController(backend)..start();
  registerStickerLicenses();
  // The packs are files of the room server, which the room controller knows the address of
  final stickers = await StickerStore.load(server: () => room.profile.server, cacheFolder: backend.cacheFolder);
  // The library of this phone changes under the person's hand or while the screen is off: the sync looks a few seconds later
  backend.events.where((e) => e is LibraryEvent).listen((_) => sync.libraryChanged());
  library.onHistoryCleared = sync.historyCleared;
  WidgetsBinding.instance.addObserver(_SyncOnLifecycle(sync, connect));
  unawaited(sync.load());
  runApp(
    SapocheApp(
      model: AppModel(
        sync: sync,
        connect: connect,
        room: room,
        settings: settings,
        recents: recents,
        library: library,
        searches: searches,
        music: MusicController(backend),
        comments: CommentsController(
          CommentsClient(
            createCommentsTransport(backend),
            region: () => PlatformDispatcher.instance.locale.countryCode ?? 'US',
          ),
        ),
        update: UpdateController(backend),
        stickers: stickers,
        clipboardHasPhotos: backend.clipboardHasPhotos,
        clipboardPhotos: backend.clipboardPhotos,
      ),
    ),
  );
}

/// Asked when needed: a TV is known only once the app has asked the device, and the screen has its size by then.
DeviceKind _deviceKind() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  return DeviceKind.detect(
    web: kIsWeb,
    platform: defaultTargetPlatform,
    tv: Tv.on.value,
    shortSideDp: view == null ? 0 : view.physicalSize.shortestSide / view.devicePixelRatio,
  );
}

String _deviceLabel() => kIsWeb
    ? 'Web'
    : Tv.on.value
    ? 'Android TV'
    : (defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android');

/// Syncs when the app comes back to the front and when it goes away (an iPhone gives it a few seconds; the next run makes up).
class _SyncOnLifecycle with WidgetsBindingObserver {
  _SyncOnLifecycle(this._sync, this._connect);

  final SyncController _sync;
  final ConnectController _connect;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || state == AppLifecycleState.paused) _sync.appMoved();
    // Back in front: the line to the other devices is tried again at once if it was lost
    if (state == AppLifecycleState.resumed) _connect.nudge();
  }
}
