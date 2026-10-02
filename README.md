# Unison

Listen to YouTube music together, in sync, wherever you are.

An Android and iPhone app for a small group of friends. Every phone fetches the audio stream by itself, on the device; a free server (Cloudflare Workers) only keeps the rooms and the sync clock. It never holds any music.

> **This is a vibe-coded project.** Almost all of the code, tests and documentation were written by an AI coding assistant (Claude Code), directed by a person who describes what they want, tries it on real phones and decides what stays. It is a personal hobby project: expect rough edges, read the code before you trust it, and do not treat it as production software.

## What it does

- Plays music like an ordinary player: search, a personal queue, background playback, lock-screen controls.
- Rooms: create a room or join one with a code; everybody hears the same song at the same moment, and anyone can add songs and steer playback (the room owner can limit guests to adding songs).
- Over-the-air updates for the app, English and Vietnamese interface, battery and heat saving modes.

## Layout

| Folder | What is in it |
|---|---|
| [app/](app/README.md) | The Flutter app (UI) and the Kotlin playback service (Media3) |
| [app/packages/unison_native/](app/packages/unison_native/) | The iOS native side in Swift: player, room, YouTube, library; its core is tested on Linux |
| [native/](native/) | Plain Kotlin libraries: YouTube stream extraction and room sync, with JVM tests |
| [server/](server/README.md) | The room server on Cloudflare Workers and Durable Objects |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The sync protocol between the app and the server |

## Running it yourself

You need Flutter, JDK 17, the Android SDK and a free Cloudflare account. The room key and the app signing key are yours and are never committed. To set up the server, the key and the app build, see [server/README.md](server/README.md) and [app/README.md](app/README.md).

## iPhone

The iOS app shares the Flutter UI with Android; its native side is rewritten in Swift (AVFoundation) and speaks the same room protocol as the server. Apple does not allow free, lasting installs outside the App Store, so this build is for personal use only:

- GitHub Actions builds an unsigned IPA ([.github/workflows/ios.yml](.github/workflows/ios.yml)); you download it and sign it with your own Apple ID through [SideStore](https://sidestore.io) (a free certificate expires after 7 days; SideStore renews it by itself while the phone is on the same Wi-Fi).
- The server address and the room key are not in the app. The easy way: on an Android phone that already works, open Settings > Set up another phone to show a QR code, then scan it with the iPhone's Camera (or copy the `unison://setup?…` link and paste it in Settings > Server); the app asks before using it. You can also type them in Settings > Server.
- There are no over-the-air updates (SideStore handles that), and battery use has not been measured on many devices.

## Notes

This is a personal project, written to listen to music with friends in a small group, with no commercial purpose. Getting streams from YouTube with a third-party client is not covered by YouTube's terms of service, so decide for yourself before using it, and do not use it to store or redistribute music.
