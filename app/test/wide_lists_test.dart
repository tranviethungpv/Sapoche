import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/collection_screen.dart' show openCollection;
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/room_page.dart' show RoomPage;
import 'package:sapoche/ui/player/lyrics_view.dart';
import 'package:sapoche/ui/player/up_next_view.dart';
import 'package:sapoche/ui/widgets/glass.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';
import 'package:sapoche/ui/widgets/track_columns.dart';
import 'package:sapoche/ui/widgets/track_tile.dart';

import 'adaptive_test.dart' show pumpAt;
import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// `docs/plans/2026-11-12-ui-fixed-yardstick.md` group C (K8 to K12): the lists, the sidebar and the player in a wide window.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  tearDown(() => S.current = 'en');

  group('the empty part of the seek bar', () {
    test('is 3:1 on the page, in both themes and in the colours that can be picked', () {
      for (final brightness in Brightness.values) {
        for (final accent in [null, const Color(0xFF2E7D32), const Color(0xFFFFD600), const Color(0xFF1565C0)]) {
          final p = Palette.forAccent(accent, brightness);
          expect(_contrast(p.track, p.base), greaterThanOrEqualTo(3.0), reason: '$accent $brightness');
        }
      }
    });
  });

  group('songs in columns', () {
    const withAlbum = MusicTrack(
      videoId: 'with000000',
      title: 'With An Album',
      artist: 'Ann',
      durMs: 200000,
      album: 'The Album',
      albumId: 'MPREb_x',
      isSong: true,
    );
    const without = MusicTrack(videoId: 'without0000', title: 'Without', artist: 'Ben', durMs: 180000, isSong: true);

    Future<void> search(WidgetTester tester, double width, List<MusicTrack> songs) async {
      final (backend, _) = await pumpApp(tester);
      backend.searchPageResult = SearchResults(
        items: [for (final t in songs) SearchItem(kind: 'song', id: t.videoId, title: t.title, track: t)],
      );
      await resize(tester, width, 800);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pump(const Duration(milliseconds: 500));
      final button = find.byTooltip(S.tabSearch);
      await tester.tap(button.evaluate().isNotEmpty ? button : find.text(S.tabSearch).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'a');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
    }

    testWidgets('a wide list has the names of the columns and the album of each song', (tester) async {
      await search(tester, 1280, [withAlbum, without]);
      expect(find.byType(TrackColumnsHeader), findsOneWidget);
      expect(find.text(S.infoAlbum), findsOneWidget, reason: 'the head of the column');
      expect(find.text('The Album'), findsOneWidget);
      expect(find.byTooltip(S.infoLength), findsOneWidget);
    });

    testWidgets('has no album column when no song has an album', (tester) async {
      await search(tester, 1280, [without]);
      expect(find.text(S.infoAlbum), findsNothing);
    });

    testWidgets('a phone has no columns, and no head for them', (tester) async {
      await search(tester, 400, [withAlbum, without]);
      expect(find.text(S.infoAlbum), findsNothing);
      expect(find.text('The Album'), findsNothing);
    });

    testWidgets('a row without an album is not stretched across the window', (tester) async {
      final backend = await pumpAt(tester, 1280, 800);
      backend.emit(StateEvent(sampleRoom(songs: 3)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.tabRoom).first);
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byType(TrackTile).first);
      final heart = tester.getRect(find.byIcon(Icons.favorite_border_rounded).first);
      // The length and the heart are within the width of a line, 760 dp and its padding, from the row's left edge
      expect(heart.right - row.left, lessThanOrEqualTo(TrackColumns.maxContent(album: false) + 40));
    });
  });

  group('the sidebar lights one row', () {
    Future<void> open(WidgetTester tester) async {
      final backend = await pumpAt(tester, 1280, 800);
      backend.likedSongs = const [Track(videoId: 'liked000000', title: 'Liked', artist: 'A', durMs: 1000)];
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
    }

    /// Whether the row with [label] in the sidebar is the lit one: it has a veil under it, the others none.
    bool lit(WidgetTester tester, String label) {
      final text = find.descendant(of: find.byType(Glass).first, matching: find.text(label)).first;
      final row = tester.widget<Material>(find.ancestor(of: text, matching: find.byType(Material)).first);
      return row.color != Colors.transparent;
    }

    testWidgets('Settings, when it is open, and not Home', (tester) async {
      await open(tester);
      expect(lit(tester, S.tabHome), isTrue);
      await tester.tap(find.text(S.settingsTitle).last);
      await tester.pumpAndSettle();
      expect(lit(tester, S.settingsTitle), isTrue);
      expect(lit(tester, S.tabHome), isFalse);
    });

    testWidgets('a list of the library from the sidebar, and not Library', (tester) async {
      await open(tester);
      await tester.tap(find.text(S.likedSongs).first);
      await tester.pumpAndSettle();
      expect(lit(tester, S.likedSongs), isTrue);
      expect(lit(tester, S.tabLibrary), isFalse);
    });

    testWidgets('and the gear at the top of Home is not there, as Settings is a row of the sidebar', (tester) async {
      await open(tester);
      expect(find.byTooltip(S.settingsTitle), findsNothing);
    });
  });

  group('the player in a wide window', () {
    Future<void> openPlayer(WidgetTester tester) async {
      await pumpAt(tester, 1280, 800);
      final bar = find.byType(PlayerBar);
      await tester.tapAt(tester.getTopLeft(bar) + const Offset(40, 30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    testWidgets('has the queue beside the picture, and touching its button again leaves it there', (tester) async {
      await openPlayer(tester);
      expect(find.byType(UpNextView), findsOneWidget);
      await tester.tap(find.byTooltip(S.upNext));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(UpNextView), findsOneWidget);
    });

    testWidgets('has the lyrics when asked, and the queue back when asked', (tester) async {
      await openPlayer(tester);
      await tester.tap(find.byTooltip(S.lyrics));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(UpNextView), findsNothing);
      await tester.tap(find.byTooltip(S.upNext));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(UpNextView), findsOneWidget);
      expect(find.byType(LyricsView), findsNothing);
    });
  });

  testWidgets('the last row of a long list, scrolled to the end, is above the player bar in a wide window', (tester) async {
    final (backend, _) = await pumpApp(tester);
    await resize(tester, 1280, 800);
    backend.emit(StateEvent(sampleRoom(songs: 16)));
    backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(RoomPage), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Song 15'), 300, scrollable: list);
    await tester.fling(list, const Offset(0, -3000), 4000);
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(PlayerBar));
    expect(tester.getRect(find.text('Song 15')).bottom, lessThanOrEqualTo(bar.top));
  });

  testWidgets('a row of an album is never lower than 52 dp', (tester) async {
    final (backend, _) = await pumpApp(tester, listen: false);
    backend.emit(const StateEvent(RoomSnapshot()));
    backend.collectionResult = const CollectionPage(
      id: 'MPREb_a',
      title: 'An Album',
      kind: 'Album',
      owner: 'Zen',
      tracks: [MusicTrack(videoId: 'albumsong01', title: 'One', artist: 'Zen', durMs: 200000, isSong: true)],
    );
    await tester.pumpAndSettle();
    openCollection(tester.element(find.byType(HomeShell)), id: 'MPREb_a', title: 'An Album');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TrackTile).first).height, greaterThanOrEqualTo(52));
  });
}
