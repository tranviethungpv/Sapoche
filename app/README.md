# Sapoche (Flutter app)

The Flutter UI. Playback and room sync live in the Kotlin part under `android/` (sync protocol: [docs/PROTOCOL.md](../docs/PROTOCOL.md)).

```
lib/
  theme/     the light pink palette (light and dark) and ThemeData
  data/      models, the bridge to Kotlin (backend.dart), RoomController
  ui/        screens and widgets
  strings.dart   every piece of text shown
android/app/src/main/kotlin/app/sapoche/
  SapocheBridge.kt   MethodChannel + EventChannel between Flutter and native
  PlaybackService.kt, GroupController.kt, ExoPlayerPort.kt   playback and joining rooms
../native/{core,sync}   YouTube stream extraction and the sync engine, shared with the spikes
```

## Running it

```bash
export PATH=$HOME/.local/share/flutter/bin:$PATH
# the key shared with the server (not committed): create android/sapoche.properties with
#   sapoche.roomKey=<key>
#   sapoche.serverUrl=<server address>
flutter pub get
flutter run            # or: flutter build apk --debug
```

If you change the server key, build and reinstall the app for the whole group (see [server/README.md](../server/README.md)).

## Tests

```bash
flutter analyze && flutter test        # UI, controllers, channel contracts
cd android && ./gradlew :core:test :sync:test   # link parsing, the sync engine
```

`tool/soak.sh` runs a listening session with the screen off on devices that joined the same room (the volume must be 0 beforehand) and prints the number of song changes, rewinds, errors and the drift. `tool/battery.sh` measures the app's CPU time, frames and reconnects over a period, to compare two builds on the same device. Both switch the screen off with the power key: a device with a screen lock gets locked and can only be unlocked by hand.

## Releasing

`tool/release.sh` builds, signs and checks the release APK; with `--publish` it also uploads it for the app's own updates (see the notes at the top of the script). Wrangler needs Node 22 or newer: if that is not the Node on the PATH, give the folder of one in `NODE_BIN`.

## iOS

The iOS native side is the Flutter plugin [packages/sapoche_native](packages/sapoche_native/) (Swift, no Android part). It speaks over the same two channels, `app.sapoche/control` and `app.sapoche/state`, as `SapocheBridge.kt`, so the Dart UI is the same on both.

```
packages/sapoche_native/ios/sapoche_native/Sources/sapoche_native/
  Core/    the plain-Foundation part: room sync, queue, YouTube, the SQLite library, Bridge.swift (the UI's commands)
  Apple/   the part that only runs on an iPhone: AVPlayerEngine, lock screen, file pickers, network, the plugin
```

`Core/` compiles and its tests run on Linux (no Mac needed): `cd packages/sapoche_native && swift test`. `Apple/` only compiles on macOS, so CI (`.github/workflows/ios.yml`) builds the whole app. To install: download the unsigned IPA from CI and sign it with SideStore. The server address and the room key are not built into the IPA: Android shows them as a QR code (Settings > Set up another phone, link `sapoche://setup?server=…&key=…`), and the iPhone scans it with Camera or pastes the link in Settings > Server; typing them in works too. To measure frame times on an iPhone, build with `--dart-define=FRAME_STATS=true`: the figures go to the log (Settings > Copy log). Measured on 2026-10-02: a 120 Hz screen, a frame interval of 8.3 ms.

YouTube songs arrive as fragmented MP4 (DASH); `Core/Mp4.swift` rewrites them as plain MP4 right after the download (no re-encoding), because AVPlayer is unreliable with fragmented files on disk.

## Inviting friends

The "Room" sheet inside a room has a 6-character code, a QR code and a link `https://<server>/join/CODE`; the share button sends the code with that link (it is tappable in chat apps). For an installed app, Android verifies the server address through `/.well-known/assetlinks.json` (the signing key fingerprint is in `server/src/join-page.ts`; edit it there when the signing key changes) and opens the app directly; until it is verified, the server page tries to open the app and then shows the code to type. The older `sapoche://join/CODE` links still work. Opening a link while outside a room opens the Room sheet with the code filled in; while in another room it asks whether to switch.

## Listening outside a room

Opening the app lands on the personal queue (kept in `files/local_queue.json`, and back after a restart in the paused state). The "Room" button at the top leads to a sheet for creating a room, joining by code, or rejoining a recent one.
