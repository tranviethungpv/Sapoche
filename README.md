<p align="center">
  <img src="docs/images/logo.png" alt="Sapoche" width="120" height="120">
</p>

<h1 align="center">Sapoche</h1>

<p align="center">
  <strong>Listen to YouTube music together, in sync, wherever you are.</strong><br>
  A free music app for a small group of friends: Android, iPhone, tablets and the web.
</p>

<p align="center">
  <img alt="Android" src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="iOS" src="https://img.shields.io/badge/iOS-iPhone-000000?logo=apple&logoColor=white">
  <img alt="Web" src="https://img.shields.io/badge/Web-Flutter-02569B?logo=flutter&logoColor=white">
  <img alt="Cost" src="https://img.shields.io/badge/running%20cost-%240-C4456B">
</p>

<p align="center">
  <img src="docs/images/hero.webp" alt="Sapoche on a phone and a tablet, playing MAKING MY WAY, and a room with two devices listening" width="100%">
</p>

Every phone fetches the audio stream by itself, on the device; a free server (Cloudflare Workers) only keeps the rooms and the sync clock. It never holds any music.

> **This is a vibe-coded project.** Almost all of the code, tests and documentation were written by an AI coding assistant (Claude Code), directed by a person who describes what they want, tries it on real phones and decides what stays. It is a personal hobby project: expect rough edges, read the code before you trust it, and do not treat it as production software.

## Highlights

- **One beat, many devices.** Create a room or join one with a code, a QR code or a link. Everybody hears the same song at the same moment, and anyone can add songs and steer playback (the owner can limit guests to adding songs).
- **A player that keeps playing.** Background playback and lock-screen controls come first: the stream is fetched on each device, so it keeps going with the screen off.
- **Music that knows you.** A home page with a mix for each kind of music you play, moods, charts, the latest from your artists and something new, learned from what you hear, like and skip, on the phone only.
- **Made for phones and tablets.** A bottom bar on a phone, a side bar and two-column pages on a tablet, light and dark themes, and an accent colour of your own (Settings > Appearance).
- **Talk while you listen.** Chat in the room with replies and reactions, with an optional end-to-end encryption, and a look of its own for each room.
- **Your music, your rules.** Search YouTube and YouTube Music, a personal queue, playlists, downloads, the music files already on the phone, lyrics that follow the song, a sleep timer and a choice of sound quality.

<p align="center">
  <img src="docs/images/phones.webp" alt="Home, search, the player in the dark theme and the player in the light theme on a phone" width="100%">
</p>

## In a room

Everyone in a room sees who is there, who added each song and what comes next, on a phone as well as on a tablet.

<p align="center">
  <img src="docs/images/room.webp" alt="A room with two people listening, shown on a tablet and on a phone at the same time" width="100%">
</p>

## On a tablet

On a wide screen the app gives the pages two halves and moves the tabs to a side bar. Pick the colour of the whole app from eight shades, or mix your own.

<p align="center">
  <img src="docs/images/tablets.webp" alt="An artist page and the settings with the choice of an accent colour, on a tablet" width="100%">
</p>

<sub>The screenshots were taken on a Sharp phone and an Android tablet emulator, playing <em>MAKING MY WAY</em> by Sơn Tùng M-TP. The song and its cover art belong to their owners; they are shown only to give the app something real to play.</sub>

## Everything it does

- Plays music like an ordinary player: search, a personal queue, background playback, lock-screen controls.
- Rooms: create a room or join one with a code; everybody hears the same song at the same moment, and anyone can add songs and steer playback (the room owner can limit guests to adding songs).
- Suggestions that learn from what you hear, like and skip, on the phone only: a home page with a mix for each kind of music you play, moods, charts, the latest from your artists and something new, and a way to say "not interested".
- A choice of sound quality, from little data to the best YouTube offers (about 160 kbps).
- Plays the music files that are already on the phone, next to YouTube songs, in the personal queue and in playlists. On Android they are read from the phone's music library once you allow it; on an iPhone they live in the Sapoche folder of the Files app. They stay on the phone: they cannot be added to a room and they are not part of a backup.
- Over-the-air updates for the app, English and Vietnamese interface, battery and heat saving modes.

## Layout

| Folder | What is in it |
|---|---|
| [app/](app/README.md) | The Flutter app (UI) and the Kotlin playback service (Media3) |
| [app/packages/sapoche_native/](app/packages/sapoche_native/) | The iOS native side in Swift: player, room, YouTube, library; its core is tested on Linux |
| [native/](native/) | Plain Kotlin libraries: YouTube stream extraction and room sync, with JVM tests |
| [server/](server/README.md) | The room server on Cloudflare Workers and Durable Objects |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The sync protocol between the app and the server |

## Running it yourself

You need Flutter, JDK 17, the Android SDK and a free Cloudflare account. The room key and the app signing key are yours and are never committed. To set up the server, the key and the app build, see [server/README.md](server/README.md) and [app/README.md](app/README.md).

## iPhone

The iOS app shares the Flutter UI with Android; its native side is rewritten in Swift (AVFoundation) and speaks the same room protocol as the server. Apple does not allow free, lasting installs outside the App Store, so this build is for personal use only:

- GitHub Actions builds an unsigned IPA ([.github/workflows/ios.yml](.github/workflows/ios.yml)); you download it and sign it with your own Apple ID through [SideStore](https://sidestore.io) (a free certificate expires after 7 days; SideStore renews it by itself while the phone is on the same Wi-Fi).
- The server address and the room key are not in the app. The easy way: on an Android phone that already works, open Settings > Set up another phone to show a QR code, then scan it with the iPhone's Camera (or copy the `sapoche://setup?…` link and paste it in Settings > Server); the app asks before using it. You can also type them in Settings > Server.
- There are no over-the-air updates (SideStore handles that), and battery use has not been measured on many devices.

## Notes

The app was called Unison until version 1.8.6. From 1.9.0 the name is Sapoche everywhere, the package id (`app.sapoche`) and the `sapoche://` link scheme included, so it installs next to the old app instead of updating it. To bring a library over, save a backup in the old app (Settings > Backup > Save your library to a file) and add it in the new one (Settings > Backup > Add from a backup file); backups made by the old app are still read. Downloaded songs are not part of a backup.

This is a personal project, written to listen to music with friends in a small group, with no commercial purpose. Getting streams from YouTube with a third-party client is not covered by YouTube's terms of service, so decide for yourself before using it, and do not use it to store or redistribute music.
