import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/sync/sync_controller.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/artist_page.dart';
import 'package:sapoche/ui/chat_sheet.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/player/spotify_player.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/widgets/reactions.dart' show showReactionPicker;
import 'package:sapoche/ui/widgets/player_bar.dart';

import '../fake_backend.dart';
import '../pump_app.dart';
import '../sync/sync_harness.dart';
import 'shot_data.dart';
import 'shot_harness.dart';

Future<void> _settle(WidgetTester t) => settleShot(t);

/// The engine of the library sync of the screen being drawn: a phone with a server that is only a list in memory.
SyncController? _shotSync;
SyncController _newShotSync() => _shotSync = Phone('Pixel', FakeServer(), Clock()).sync;

BuildContext _shell(WidgetTester t) => t.element(find.byType(HomeShell));

/// Sends the state the app is waiting for: out of a room, or in one.
Future<void> _state(WidgetTester t, FakeBackend b, RoomSnapshot s) async {
  b.emit(StateEvent(s));
  b.emit(const LibraryEvent());
  await _settle(t);
}

/// The playing room, with the song playing a little way in.
Future<void> _playing(WidgetTester t, FakeBackend b, {bool video = false}) async {
  await _state(t, b, busyRoom(video: video));
  b.emit(
    const PositionEvent(
      PlayerPosition(
        playing: true,
        positionMs: 64000,
        durationMs: 305000,
        audioFormat: AudioFormat(codec: 'Opus', kbps: 131, hz: 48000),
      ),
    ),
  );
  await _settle(t);
}

/// Opens the full player from whichever bar has the song: the mini player on a phone, the long bar of a wide window.
Future<void> _openPlayer(WidgetTester t, {bool settle = true}) async {
  final bar = find.byType(PlayerBar);
  // Beside the pages the player is there already
  if (find.byType(NowPlayingPage).evaluate().isNotEmpty) {
    await _settle(t);
    return;
  }
  if (bar.evaluate().isNotEmpty) {
    await t.tapAt(t.getTopLeft(bar.first) + const Offset(40, 30));
  } else {
    await tapMiniPlayer(t);
  }
  // The picture never lets the page come to rest (its controls fade on a timer): a few frames are all it gets
  if (settle) {
    await _settle(t);
  } else {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 500));
    }
  }
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

void _logData(FakeBackend b) {
  b.logLines = shotLog();
  b.logInfoLines = ['app: 1.54.1+117', 'platform: Android 14 (API 34)', 'device: SHARP SH-51G', 'abi: arm64-v8a (64-bit process)', 'locale: vi-VN', 'listening: in a room, 3 in the room'];
}

/// Opens the log page: Settings, down to Diagnostics, its row.
Future<void> _openLog(WidgetTester t, FakeBackend b) async {
  await _state(t, b, const RoomSnapshot());
  // The app opens on Home, where the gear is (on a phone on its side there is one in the sidebar too)
  final gear = find.byTooltip(S.settingsTitle);
  await t.tap(gear.evaluate().isNotEmpty ? gear.first : find.text(S.settingsTitle).first);
  await _settle(t);
  await _settle(t);
  await _revealTopic(t, 'advanced');
  await t.tap(find.byKey(const ValueKey('settings-advanced')));
  await _settle(t);
  await t.tap(find.byKey(const ValueKey('settings-log')));
  await _settle(t);
  await t.pump(const Duration(milliseconds: 200));
}

/// Opens Settings: the gear at the top of Home, or in a wide window the row of the sidebar.
/// Scrolls the list that holds [inside] until [target] shows: a row low on a long page is not built until then.
Future<void> _reveal(WidgetTester t, Finder target, Finder inside) async {
  await t.scrollUntilVisible(target, 300, scrollable: find.ancestor(of: inside, matching: find.byType(Scrollable)).first);
  await _settle(t);
}

/// Scrolls the first page of the settings until the row of [topic] shows.
Future<void> _revealTopic(WidgetTester t, String topic) =>
    _reveal(t, find.byKey(ValueKey('settings-$topic')), find.byKey(const ValueKey('settings-appearance')));

Future<void> _openSettings(WidgetTester t) async {
  final gear = find.byTooltip(S.settingsTitle);
  await t.tap(gear.evaluate().isNotEmpty ? gear : find.text(S.settingsTitle).last);
  await _settle(t);
}

Future<void> _tab(WidgetTester t, String label) async {
  await t.tap(find.text(label).last);
  await _settle(t);
}

/// Two songs on the phone, one on its way, one waiting and one that failed.
void _someDownloads(FakeBackend b) {
  const states = [DownloadState.done, DownloadState.done, DownloadState.queued, DownloadState.queued, DownloadState.failed];
  b.downloadList.addAll([
    for (final (i, t) in tracks.indexed)
      DownloadEntry(track: t, state: states[i], bytes: states[i] == DownloadState.done ? 4200000 + i * 900000 : 0),
  ]);
}

/// The playlist "Road trip" of every song, switched on ([kept]) or not, with the first [done] of them on the phone.
void _keptPlaylist(FakeBackend b, {required bool kept, required int done}) {
  b.playlistNames[1] = 'Road trip';
  b.playlistSongs[1] = [...tracks];
  if (kept) b.offlinePlaylists.add(1);
  b.removable = done;
  b.downloadList.addAll([
    for (final (i, t) in tracks.indexed)
      if (i < done) DownloadEntry(track: t, state: DownloadState.done, bytes: 4200000)
      else if (kept) DownloadEntry(track: t, state: DownloadState.queued),
  ]);
}

/// A song that did not start, told by the notice at the bottom of the playing room.
ShotScreen _notice(String name, String code) => ShotScreen('notice-$name', prepare: (b) {
  b.homeResult = homeData;
  fillLibrary(b);
}, (t, b) async {
  await _playing(t, b);
  b.emit(ErrorEvent(ServerError(code, tracks.first.title)));
  await t.pump();
  await _settle(t); // the notice slides in
});

/// Every screen of the picture set. Add a screen here, and it is drawn at every size, in both themes and languages.
final shotScreens = <ShotScreen>[
  _notice('slow', 'load_slow'),
  _notice('offline', 'load_offline'),
  _notice('skipped', 'load_skipped'),
  _notice('unplayable', 'load_unplayable'),
  _notice('broken', 'load_broken'),
  _notice('failed', 'load_failed'),
  ShotScreen('home', bigText: true, prepare: (b) {
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
  ShotScreen('room', bigText: true, listen: true, (t, b) => _playing(t, b)),
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
  ShotScreen('search', bigText: true, prepare: (b) => b.searchPageResult = searchData, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _search(t, 'sơn tùng');
  }),
  // Rows of every kind in one list, none of the songs with an album: they run as wide as the rows of an album or a podcast
  ShotScreen(
    'search-mixed',
    prepare: (b) => b.searchPageResult = const SearchResults(
      items: [
        SearchItem(
          kind: 'episode',
          id: 'ep000000001',
          title: 'Shocking! Wedding night, ugly wife turn into beautiful empress: beggar to queen in one episode of the long drama',
          subtitle: 'Episode · Aug 13 · ShuiDing',
          track: MusicTrack(videoId: 'ep000000001', title: 'Shocking! Wedding night, ugly wife turn into beautiful empress: beggar to queen in one episode of the long drama', artist: 'ShuiDing', durMs: 0),
        ),
        SearchItem(kind: 'podcast', id: 'MPSPpod1', title: 'Mục Thần Ký', subtitle: 'Podcast · Lát Radio'),
        SearchItem(kind: 'podcast', id: 'MPSPpod2', title: '[Đang ra]: Tại Fairy Tail Lại Bắt Đầu Lại Từ Đầu Sinh Hoạt - Đồng Nhân', subtitle: 'Podcast · Thích Nghe Truyện'),
        SearchItem(
          kind: 'song',
          id: 'song0000001',
          title: 'Lạnh Lẽo - Nhạc Phim Trung Hoa Bất Hủ | Tam Sinh Tam Thế',
          subtitle: 'Song · Sáo Trúc Hoàng Anh · 838K plays',
          track: MusicTrack(videoId: 'song0000001', title: 'Lạnh Lẽo - Nhạc Phim Trung Hoa Bất Hủ | Tam Sinh Tam Thế', artist: 'Sáo Trúc Hoàng Anh', durMs: 276000, isSong: true),
        ),
        SearchItem(
          kind: 'song',
          id: 'song0000002',
          title: 'Đôi Mắt Của Trái Tim',
          subtitle: 'Song · PHAM HUU TAM · 158 plays',
          track: MusicTrack(videoId: 'song0000002', title: 'Đôi Mắt Của Trái Tim', artist: 'PHAM HUU TAM', durMs: 243000, isSong: true),
        ),
        SearchItem(kind: 'album', id: 'MPREb_x', title: 'Chúng Ta Của Hiện Tại', subtitle: 'Album · Sơn Tùng M-TP · 2020'),
      ],
    ),
    (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await _search(t, 'ost tam sinh tam the');
    },
  ),
  // Nothing typed: the songs of "For you"
  ShotScreen('search-idle', prepare: (b) => b.forYouSongs = [...tracks], (t, b) async {
    await _state(t, b, const RoomSnapshot());
    // What was searched for lately runs the width of the page; the songs under it are as wide
    for (final term in ['khong phai dang vua dau', 'j97', 'hoa co lau h2k', 'the fat rat']) {
      AppScope.of(_shell(t)).searches.add(term);
    }
    final button = find.byTooltip(S.tabSearch);
    await t.tap(button.evaluate().isNotEmpty ? button : find.text(S.tabSearch).first);
    await _settle(t);
  }),
  ShotScreen('search-none', prepare: (b) => b.searchPageResult = const SearchResults(), (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _search(t, 'zzzz');
  }),
  ShotScreen('player', bigText: true, listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
  }),
  ShotScreen('player-lyrics', prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.lyrics));
    await _settle(t);
  }),
  ShotScreen('player-comments', listen: true, prepare: (b) => b.radioResult = const SongRadio(tracks: [longViVideo]), (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.youtubeComments));
    await _settle(t);
  }),
  ShotScreen('player-comments-off', listen: true, comments: shotCommentsOff, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.youtubeComments));
    await _settle(t);
  }),
  ShotScreen('player-comments-failed', listen: true, comments: shotCommentsFail, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.youtubeComments));
    await _settle(t);
  }),
  ShotScreen('player-queue', listen: true, (t, b) async {
    await _playing(t, b);
    await _openPlayer(t);
    await t.tap(find.byTooltip(S.upNext));
    await _settle(t);
  }),
  ShotScreen('player-queue-groups', listen: true, (t, b) async {
    await _state(t, b, splitQueue());
    b.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 64000, durationMs: 305000)));
    await _settle(t);
    await _openPlayer(t);
    await _openPanel(t, S.upNext);
  }),
  ShotScreen('player-land-queue-groups', windows: shotLandscape, listen: true, (t, b) async {
    await _state(t, b, splitQueue());
    b.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 64000, durationMs: 305000)));
    await _settle(t);
    await _openPlayer(t);
    await _openPanel(t, S.upNext);
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
  // A playlist kept on the phone: the round button beside Play off, on its way, all there, and the question to stop it
  for (final (name, kept, done) in const [('off', false, 0), ('coming', true, 2), ('done', true, 5)])
    ShotScreen('playlist-offline-$name', prepare: (b) => _keptPlaylist(b, kept: kept, done: done), (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await _tab(t, S.tabLibrary);
      await _tab(t, 'Road trip');
    }),
  // The pages beside the docked player: a playlist, with Play and its round buttons in the room that is left
  ShotScreen('playlist-dock', windows: shotDockPages, listen: true, prepare: (b) => _keptPlaylist(b, kept: true, done: 2), (t, b) async {
    await _playing(t, b);
    await _tab(t, S.tabLibrary);
    await _tab(t, 'Road trip');
  }),
  ShotScreen('playlist-offline-stop', prepare: (b) => _keptPlaylist(b, kept: true, done: 5), (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, 'Road trip');
    await t.tap(find.byTooltip(S.downloadedSongs));
    await _settle(t);
  }),
  ShotScreen('library-offline', prepare: (b) {
    fillLibrary(b);
    _keptPlaylist(b, kept: true, done: 5);
    b.folderNames[1] = 'Trips';
    b.offlineFolders.add(1);
    b.playlistNames[2] = 'Evening';
    b.playlistSongs[2] = [...tracks.take(2)];
    b.playlistFolders[2] = 1;
  }, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
  }),
  ShotScreen('downloaded-empty', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.downloadedSongs);
  }),
  // The page of the downloaded songs with something to say above them: a run in hand, songs that did not get downloaded
  ShotScreen('downloaded-run', prepare: _someDownloads, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.downloadedSongs);
    b.emit(DownloadsEvent(DownloadBatch(active: tracks[2].videoId, done: 2, total: 4)));
    await _settle(t);
  }),
  ShotScreen('downloaded-stuck', prepare: _someDownloads, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.downloadedSongs);
    b.emit(const DownloadsEvent(DownloadBatch(done: 2, total: 4)));
    await _settle(t);
  }),
  ShotScreen('downloaded-stuck-open', prepare: _someDownloads, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _tab(t, S.tabLibrary);
    await _tab(t, S.downloadedSongs);
    b.emit(const DownloadsEvent(DownloadBatch(done: 2, total: 4)));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('stuck-header')));
    await _settle(t);
  }),
  ShotScreen(
    'downloaded-only-stuck',
    prepare: (b) => b.downloadList.add(DownloadEntry(track: tracks[0], state: DownloadState.failed)),
    (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await _tab(t, S.tabLibrary);
      await _tab(t, S.downloadedSongs);
      b.emit(const DownloadsEvent(DownloadBatch(failed: 1, total: 1)));
      await _settle(t);
    },
  ),
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
  ShotScreen('settings', bigText: true, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
  }),
  // Each topic, by the rows that lead to it (some are a page further in)
  for (final path in [
    ['appearance'],
    ['playback'],
    ['suggestions'],
    ['suggestions', 'taste'],
    ['storage'],
    ['advanced'],
    ['advanced', 'scrobble'],
  ])
    ShotScreen('settings-${path.last}', (t, b) async {
      await _state(t, b, const RoomSnapshot());
      await t.tap(find.text(S.tabHome));
      await _settle(t);
      await _openSettings(t);
      await _settle(t);
      // The first row is on the long list of topics; the second is at the top of its page
      await _revealTopic(t, path.first);
      for (final topic in path) {
        await t.tap(find.byKey(ValueKey('settings-$topic')));
        await _settle(t);
      }
    }),
  ShotScreen('settings-sync-off', sync: _newShotSync, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-backup')));
    await _settle(t);
  }),
  ShotScreen('settings-sync-on', sync: _newShotSync, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _shotSync!.enable();
    await _shotSync!.markSaved();
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-backup')));
    await _settle(t);
  }),
  ShotScreen('sync-recovery', sync: _newShotSync, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-backup')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('sync-turn-on')));
    await _settle(t);
  }),
  ShotScreen('library-sync-card', sync: _newShotSync, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await _shotSync!.load();
    await _tab(t, S.tabLibrary);
  }),
  ShotScreen('log', prepare: _logData, (t, b) => _openLog(t, b)),
  ShotScreen('log-land', prepare: _logData, windows: shotLandscape, (t, b) => _openLog(t, b)),
  ShotScreen('log-detail', prepare: _logData, (t, b) async {
    await _openLog(t, b);
    await t.tap(find.textContaining('player error', findRichText: true).first);
    await _settle(t);
  }),
  ShotScreen('log-all', prepare: _logData, (t, b) async {
    await _openLog(t, b);
    await t.tap(find.text(S.logModeAll));
    await _settle(t);
  }),
  ShotScreen('log-clean', prepare: (b) {
    b.logLines = [for (final l in shotLog().skip(12)) if (!l.contains(' E [') && !l.contains(' W [') && !l.contains(' K [mark]')) l];
    b.logInfoLines = ['app: 1.54.1+117', 'platform: iOS 18.1'];
  }, (t, b) => _openLog(t, b)),
  ShotScreen('log-empty', prepare: (b) => b.logLines = [], (t, b) => _openLog(t, b)),
  ShotScreen('settings-scrobble-connected', prepare: (b) {
    b.scrobble = const ScrobbleState(connected: true, user: 'tvh', pending: 3);
  }, (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await _revealTopic(t, 'advanced');
    await t.tap(find.byKey(const ValueKey('settings-advanced')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-scrobble')));
    await _settle(t);
  }),
  // The heights of the picture, shared across the width, and the notes under the cards
  ShotScreen('settings-video', windows: const [ShotSize('w411', 411, 914)], (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-playback')));
    await _settle(t);
    await t.scrollUntilVisible(find.byKey(const ValueKey('setting-quality-720')), 300);
    await t.drag(find.byType(Scrollable).last, const Offset(0, -150));
    await _settle(t);
  }),
  ShotScreen('settings-equalizer', (t, b) async {
    await _state(t, b, const RoomSnapshot());
    await t.tap(find.text(S.tabHome));
    await _settle(t);
    await _openSettings(t);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-playback')));
    await _settle(t);
    final row = find.byKey(const ValueKey('settings-equalizer'));
    await _reveal(t, row, find.byKey(const ValueKey('audio-quality-low')));
    await t.tap(row);
    await _settle(t);
  }),
  ..._dockScreens(),
  ..._tvScreens(),
  ..._playerStyleScreens(PlayerStyle.spotify, 'spotify'),
  ..._playerStyleScreens(PlayerStyle.appleMusic, 'apple'),
  // The three on a phone on its side, each with a small layout of its own (beside the pages, or a sheet when too narrow)
  for (final (style, suffix) in [
    (PlayerStyle.classic, ''),
    (PlayerStyle.spotify, '-spotify'),
    (PlayerStyle.appleMusic, '-apple'),
  ]) ...[
    ShotScreen('player-land$suffix', style: style, windows: shotLandscape, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
    }),
    ShotScreen('player-land-lyrics$suffix', style: style, windows: shotLandscape, prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
      await _openPanel(t, S.lyrics);
    }),
    ShotScreen('player-land-queue$suffix', style: style, windows: shotLandscape, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
      await _openPanel(t, S.upNext);
    }),
  ],
];

/// Opens the panel with [title] (Lyrics, Up next): the button of that name where the player has one, else the card of the
/// style of cards, which is under the cover and the song, so the column is scrolled to it.
Future<void> _openPanel(WidgetTester t, String title) async {
  final button = find.descendant(of: find.byType(NowPlayingPage), matching: find.byTooltip(title));
  if (button.evaluate().isNotEmpty) {
    await t.tap(button);
    return _settle(t);
  }
  var scroll = find.descendant(of: find.byType(SpotifyPlayer), matching: find.byType(CustomScrollView));
  if (scroll.evaluate().isEmpty) {
    scroll = find.descendant(of: find.byType(SpotifyPlayer), matching: find.byType(SingleChildScrollView));
  }
  await t.drag(scroll, const Offset(0, -150));
  await _settle(t);
  final finder = find.descendant(of: find.byType(SpotifyPlayer), matching: find.text(title));
  await t.ensureVisible(finder);
  await t.tap(finder);
  await _settle(t);
}

/// The app on a TV: the pages, and the player of each style (the cover, the lyrics, the queue, the picture), as a TV
/// draws them, whatever its density.
List<ShotScreen> _tvScreens() => [
  ShotScreen('tv-home', tv: true, windows: shotTv, (t, b) async {
    await _state(t, b, busyRoom());
    await _settle(t);
  }),
  ShotScreen('tv-library', tv: true, windows: shotTv, (t, b) async {
    await _state(t, b, busyRoom());
    await t.tap(find.byIcon(Icons.library_music_rounded).first);
    await _settle(t);
  }),
  for (final (style, suffix) in [
    (PlayerStyle.classic, ''),
    (PlayerStyle.spotify, '-spotify'),
    (PlayerStyle.appleMusic, '-apple'),
  ]) ...[
    ShotScreen('tv-player$suffix', tv: true, style: style, windows: shotTv, prepare: (b) => b.lyricsResult = lyricsData, (t, b) async {
      await _playing(t, b);
      await tapMiniPlayer(t);
      await _settle(t);
    }),
    ShotScreen('tv-player-lyrics$suffix', tv: true, style: style, windows: shotTv, prepare: (b) => b.lyricsResult = lyricsData, (t, b) async {
      await _playing(t, b);
      await tapMiniPlayer(t);
      await _settle(t);
      await _openPanel(t, S.lyrics);
    }),
    ShotScreen('tv-player-queue$suffix', tv: true, style: style, windows: shotTv, (t, b) async {
      await _playing(t, b);
      await tapMiniPlayer(t);
      await _settle(t);
      await _openPanel(t, S.upNext);
    }),
  ],
];

/// The player beside the pages on a tablet and a computer: the upright player of each style, with the cover, the lyrics
/// and the queue.
List<ShotScreen> _dockScreens() => [
  for (final (style, suffix) in [
    (PlayerStyle.classic, ''),
    (PlayerStyle.spotify, '-spotify'),
    (PlayerStyle.appleMusic, '-apple'),
  ]) ...[
    ShotScreen('player-dock$suffix', style: style, windows: shotDock, prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
      await _playing(t, b);
    }),
    ShotScreen('player-dock-queue$suffix', style: style, windows: shotDock, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPanel(t, S.upNext);
    }),
  ],
];

/// The player screens of one style of the full player, named like the classic ones with [suffix] after. The style of
/// cards has no button for the lyrics or the comments: they are cards under the cover, reached by scrolling.
List<ShotScreen> _playerStyleScreens(PlayerStyle style, String suffix) {
  Future<void> card(WidgetTester t, String title) async {
    // A wide window has no cards: the places and the buttons are the classic player's
    if (find.byTooltip(title).evaluate().isNotEmpty) {
      await t.tap(find.byTooltip(title));
      return _settle(t);
    }
    var scroll = find.descendant(of: find.byType(SpotifyPlayer), matching: find.byType(CustomScrollView));
    // A phone on its side scrolls a column instead of a page
    if (scroll.evaluate().isEmpty) {
      scroll = find.descendant(of: find.byType(SpotifyPlayer), matching: find.byType(SingleChildScrollView));
    }
    await t.drag(scroll, const Offset(0, -700));
    await _settle(t);
    final finder = find.descendant(of: find.byType(SpotifyPlayer), matching: find.text(title));
    await t.ensureVisible(finder);
    await t.tap(finder);
    await _settle(t);
  }

  Future<void> comments(WidgetTester t) async {
    if (style == PlayerStyle.spotify) return card(t, S.youtubeComments);
    await t.tap(find.byTooltip(S.youtubeComments));
    await _settle(t);
  }

  return [
    ShotScreen('player-video-$suffix', style: style, listen: true, (t, b) async {
      await _playing(t, b, video: true);
      await _openPlayer(t, settle: false);
    }),
    ShotScreen('player-video-land-$suffix', style: style, windows: shotLandscape, listen: true, (t, b) async {
      await _playing(t, b, video: true);
      await _openPlayer(t, settle: false);
    }),
    ShotScreen('player-$suffix', style: style, prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
    }),
    if (style == PlayerStyle.spotify)
      ShotScreen('player-$suffix-cards', style: style, prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
        await _playing(t, b);
        await _openPlayer(t);
        await t.drag(find.descendant(of: find.byType(SpotifyPlayer), matching: find.byType(CustomScrollView)), const Offset(0, -600));
        await _settle(t);
      }),
    ShotScreen('player-lyrics-$suffix', style: style, prepare: (b) => b.lyricsResult = lyricsData, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
      if (style == PlayerStyle.spotify) {
        await card(t, S.lyrics);
      } else {
        await t.tap(find.byTooltip(S.lyrics));
        await _settle(t);
      }
    }),
    ShotScreen('player-comments-$suffix', style: style, listen: true, prepare: (b) => b.radioResult = const SongRadio(tracks: [longViVideo]), (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
      await comments(t);
    }),
    ShotScreen('player-queue-$suffix', style: style, listen: true, (t, b) async {
      await _playing(t, b);
      await _openPlayer(t);
      await t.tap(find.byTooltip(S.upNext));
      await _settle(t);
    }),
  ];
}
