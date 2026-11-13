import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/artist_page.dart';
import 'package:sapoche/ui/chat_sheet.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/widgets/reactions.dart' show showReactionPicker;
import 'package:sapoche/ui/widgets/player_bar.dart';

import '../fake_backend.dart';
import '../pump_app.dart';
import 'shot_data.dart';
import 'shot_harness.dart';

Future<void> _settle(WidgetTester t) => settleShot(t);

BuildContext _shell(WidgetTester t) => t.element(find.byType(HomeShell));

/// Sends the state the app is waiting for: out of a room, or in one.
Future<void> _state(WidgetTester t, FakeBackend b, RoomSnapshot s) async {
  b.emit(StateEvent(s));
  b.emit(const LibraryEvent());
  await _settle(t);
}

/// The playing room, with the song playing a little way in.
Future<void> _playing(WidgetTester t, FakeBackend b) async {
  await _state(t, b, busyRoom());
  b.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 64000, durationMs: 305000)));
  await _settle(t);
}

/// Opens the full player from whichever bar has the song: the mini player on a phone, the long bar of a wide window.
Future<void> _openPlayer(WidgetTester t) async {
  final bar = find.byType(PlayerBar);
  if (bar.evaluate().isNotEmpty) {
    await t.tapAt(t.getTopLeft(bar.first) + const Offset(40, 30));
  } else {
    await tapMiniPlayer(t);
  }
  await _settle(t);
}

/// Opens the search page and looks up [text]: a button on a phone, a field in the sidebar of a wide window.
Future<void> _search(WidgetTester t, String text) async {
  final button = find.byTooltip(S.tabSearch);
  await t.tap(button.evaluate().isNotEmpty ? button : find.text(S.tabSearch).first);
  await _settle(t);
  await t.enterText(find.byType(TextField).first, text);
  await t.testTextInput.receiveAction(TextInputAction.search);
  await _settle(t);
}

/// Opens Settings: the gear at the top of Home, or in a wide window the row of the sidebar.
Future<void> _openSettings(WidgetTester t) async {
  final gear = find.byTooltip(S.settingsTitle);
  await t.tap(gear.evaluate().isNotEmpty ? gear : find.text(S.settingsTitle).last);
  await _settle(t);
}

Future<void> _tab(WidgetTester t, String label) async {
  await t.tap(find.text(label).last);
  await _settle(t);
}

/// Every screen of the picture set. Add a screen here, and it is drawn at every size, in both themes and languages.
final shotScreens = <ShotScreen>[
  ShotScreen('home', prepare: (b) {
    b.homeResult = homeData;
    fillLibrary(b);
  }, (t, b) => _state(t, b, const RoomSnapshot())),
  ShotScreen('home-in-room', prepare: (b) {
    b.homeResult = homeData;
    fillLibrary(b);
  }, (t, b) => _state(t, b, busyRoom())),
  ShotScreen('library', prepare: fillLibrary, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
  }),
  ShotScreen('library-empty', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
  }),
  ShotScreen('liked', prepare: fillLibrary, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.likedSongs);
  }),
  ShotScreen('liked-empty', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.likedSongs);
  }),
  ShotScreen('recent', prepare: fillLibrary, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.recentlyPlayed);
  }),
  ShotScreen('listen', prepare: fillLibrary, listen: true, (t, b) async {
    b.emit(StateEvent(sampleRoom(local: true, songs: 4)));
    await _settle(t);
  }),
  ShotScreen('room', listen: true, (t, b) => _playing(t, b)),
  ShotScreen('room-played', listen: true, (t, b) async {
    await _state(t, b, busyRoom(index: 3));
    b.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 64000, durationMs: 295000)));
    await _settle(t);
  }),
  ShotScreen('room-offline', listen: true, (t, b) => _state(t, b, busyRoom(link: Link.closed))),
  ShotScreen('chat-empty', listen: true, (t, b) async {
    await _state(t, b, busyRoom());
    showChatSheet(_shell(t));
    await _settle(t);
  }),
  ShotScreen('reactions', listen: true, (t, b) async {
    await _playing(t, b);
    showReactionPicker(_shell(t), AppScope.roomOf(_shell(t)));
    await _settle(t);
  }),
  ShotScreen('room-empty', (t, b) => _state(t, b, sampleRoom(songs: 0, phase: 'idle'))),
  ShotScreen('search', prepare: (b) => b.searchPageResult = searchData, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _search(t, 'sơn tùng');
  }),
  ShotScreen('search-none', prepare: (b) => b.searchPageResult = const SearchResults(), (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _search(t, 'zzzz');
  }),
  ShotScreen('player', listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
  }),
  ShotScreen('player-lyrics', prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.lyrics));
    await _settle(t);
  }),
  ShotScreen('player-queue', listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.upNext));
    await _settle(t);
  }),
  ShotScreen('player-queue-empty', listen: true, prepare: (b) => b.radioResult = SongRadio(tracks: tracks.sublist(1)), (t, b) async {
    await _state(t, b, sampleRoom(local: true, songs: 1));
    b.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
    await _settle(t);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.upNext));
    await _settle(t);
  }),
  ShotScreen('track-menu', prepare: fillLibrary, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.likedSongs);
    await t.tap(find.byIcon(Icons.more_horiz_rounded).at(1));
    await _settle(t);
  }),
  ShotScreen('collection-menu', prepare: fillLibrary, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.likedSongs);
    await t.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await _settle(t);
  }),
  ShotScreen(
    'playlist-empty',
    prepare: (b) {
      b.playlistNames[1] = 'Road trip';
      b.playlistSongs[1] = [];
    },
    (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await _tab(t, S.tabLibrary);
      await _tab(t, 'Road trip');
    },
  ),
  ShotScreen('downloaded-empty', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.downloadedSongs);
  }),
  ShotScreen('album', prepare: (b) => b.collectionResult = albumPage, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    openCollection(_shell(t), id: albumPage.id, title: albumPage.title);
    await _settle(t);
  }),
  ShotScreen('artist', prepare: (b) {
    b.artistResult = artistPage;
    b.collectionResult = const CollectionPage(id: 'OLAKtop', title: 'Top songs', tracks: tracks);
  }, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    openArtist(_shell(t), artistPage.id);
    await _settle(t);
  }),
  ShotScreen('settings', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
  }),
  for (final topic in ['appearance', 'playback', 'suggestions', 'storage'])
    ShotScreen('settings-$topic', (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await t.tap(find.text(S.tabHome));
      await _settle(t);
      await _openSettings(t);
      await _settle(t);
      await t.tap(find.byKey(ValueKey('settings-$topic')));
      await _settle(t);
    }),
];
