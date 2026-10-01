// Pictures of the screens, for looking at how the app is drawn without a phone. Skipped in the ordinary run:
//   flutter test test/shots_test.dart --dart-define=SHOTS=true --update-goldens
// The pictures land in test/shots/ (not kept in git).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/music_models.dart';
import 'package:unison/ui/widgets/mini_player.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

const _wanted = bool.fromEnvironment('SHOTS');

Track _song(String id, String title, String artist) =>
    Track(videoId: id, title: title, artist: artist, durMs: 214000);

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final bytes = await File(path).readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  final flutter =
      Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/.local/share/flutter';
  await load('Inter', 'assets/fonts/Inter.ttf');
  await load(
    'MaterialIcons',
    '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('shots/$name.png'),
  );
}

Future<FakeBackend> _open(
  WidgetTester tester, {
  bool listen = false,
  bool dark = false,
}) async {
  final (backend, _) = await pumpApp(
    tester,
    listen: listen,
    mode: dark ? ThemeMode.dark : ThemeMode.light,
  );
  backend.trendingResult = [
    MusicShelf(
      title: 'Featured playlists',
      playlists: [
        Release(id: 'PL1', title: 'Chill Mix', subtitle: 'Playlist'),
        Release(id: 'PL2', title: 'Late Night Drive', subtitle: 'Playlist'),
        Release(id: 'PL3', title: 'Acoustic Morning', subtitle: 'Playlist'),
      ],
    ),
    MusicShelf(
      title: "Today's hits",
      tracks: [
        MusicTrack(
          videoId: 'hit1aaaaaaa',
          title: 'Hit One',
          artist: 'Star',
          durMs: 1000,
        ),
        MusicTrack(
          videoId: 'hit2aaaaaaa',
          title: 'Second Wave',
          artist: 'Band',
          durMs: 1000,
        ),
        MusicTrack(
          videoId: 'hit3aaaaaaa',
          title: 'Evening Light',
          artist: 'Duo',
          durMs: 1000,
        ),
      ],
    ),
  ];
  backend.recentSongs = [
    HistoryEntry(
      track: _song('annaaaaaaaa', 'Hello', 'Adele'),
      at: DateTime.now().subtract(const Duration(days: 1)),
      plays: 5,
    ),
    HistoryEntry(
      track: _song('beckaaaaaaa', 'Loser', 'Beck'),
      at: DateTime.now().subtract(const Duration(days: 2)),
    ),
  ];
  backend.likedSongs = [_song('oldaaaaaaaa', 'Old Favourite', 'Cher')];
  backend.searchResults = [
    _song('s1aaaaaaaaa', 'Blinding Lights', 'The Weeknd'),
    _song('s2aaaaaaaaa', 'Levitating', 'Dua Lipa'),
    _song('s3aaaaaaaaa', 'As It Was', 'Harry Styles'),
  ];
  backend.emit(StateEvent(sampleRoom(local: true, songs: 5, index: 1)));
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  if (!_wanted) return;

  setUpAll(_loadFonts);

  for (final dark in [false, true]) {
    final suffix = dark ? 'dark' : 'light';

    Future<FakeBackend> open(WidgetTester tester, {bool listen = false}) =>
        _open(tester, listen: listen, dark: dark);

    testWidgets('home $suffix', (tester) async {
      await open(tester);
      await _shot(tester, 'home_$suffix');
    });

    testWidgets('listen $suffix', (tester) async {
      await open(tester, listen: true);
      await _shot(tester, 'listen_$suffix');
    });

    testWidgets('search $suffix', (tester) async {
      await open(tester);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'blinding');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await _shot(tester, 'search_$suffix');
    });

    testWidgets('library $suffix', (tester) async {
      await open(tester);
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      await _shot(tester, 'library_$suffix');
    });

    testWidgets('settings $suffix', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Settings'));
      await _shot(tester, 'settings_$suffix');
    });

    testWidgets('player $suffix', (tester) async {
      await open(tester);
      await tester.tap(find.byType(MiniPlayer));
      await tester.pump(const Duration(milliseconds: 700));
      await _shot(tester, 'player_$suffix');
    });

    testWidgets('room sheet $suffix', (tester) async {
      await open(tester, listen: true);
      await tester.tap(find.text('Room').first);
      await _shot(tester, 'roomsheet_$suffix');
    });
  }
}
