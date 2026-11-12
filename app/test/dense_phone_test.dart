import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/collection_screen.dart' show openCollection;
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/player/up_next_view.dart';
import 'package:sapoche/ui/widgets/edge_fade.dart';
import 'package:sapoche/ui/widgets/menu_lines.dart';
import 'package:sapoche/ui/widgets/reactions.dart';
import 'package:sapoche/ui/widgets/track_tile.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// `docs/plans/2026-11-12-ui-fixed-yardstick.md` group D (K13 to K17): density on a phone.
void main() {
  tearDown(() => S.current = 'en');

  Future<FakeBackend> openQueue(WidgetTester tester, {bool inRoom = false}) async {
    final (backend, _) = await pumpApp(tester);
    await resize(tester, 411, 914);
    backend.radioResult = SongRadio(
      tracks: [
        for (var i = 0; i < 10; i++)
          MusicTrack(videoId: 'radio${i}xxxxx', title: 'Radio $i', artist: 'Artist $i', durMs: 200000, isSong: true),
      ],
    );
    backend.emit(StateEvent(sampleRoom(local: !inRoom, songs: 1, roomAutoplay: inRoom ? true : null)));
    backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tapMiniPlayer(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byTooltip(S.upNext));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    return backend;
  }

  group('the queue with only autoplay in it', () {
    testWidgets('has one line for what autoplay is, and no "Up next" and "nothing queued" over it', (tester) async {
      await openQueue(tester);
      expect(find.textContaining(S.autoplayShort, findRichText: true), findsOneWidget);
      expect(find.text(S.nothingAfter), findsNothing);
      expect(find.text(S.upNext), findsNothing, reason: 'only the button of the panel has that name');
    });

    testWidgets('in a room it is the room that plays after the queue', (tester) async {
      await openQueue(tester, inRoom: true);
      expect(find.textContaining(S.roomAutoplayShort, findRichText: true), findsOneWidget);
    });

    testWidgets('fades its last row with a mask: a veil of the plain background shows as a pale band on the cover\'s tint', (tester) async {
      await openQueue(tester);
      expect(find.descendant(of: find.byType(UpNextView), matching: find.byType(EdgeFade)), findsOneWidget);
    });

    testWidgets('shows at least three and a half songs on a phone', (tester) async {
      await openQueue(tester);
      final view = tester.getRect(find.byType(UpNextView));
      var seen = 0.0;
      for (final e in find.byType(TrackTile).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        final visible = (r.bottom.clamp(view.top, view.bottom) - r.top.clamp(view.top, view.bottom)) / r.height;
        seen += visible;
      }
      expect(seen, greaterThanOrEqualTo(3.5));
    });
  });

  group('a list of the library with an icon for a cover', () {
    testWidgets('has a small tile beside its name on a phone, and Play near the top', (tester) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.likedSongs = const [Track(videoId: 'liked000000', title: 'Liked', artist: 'A', durMs: 1000)];
      await resize(tester, 411, 914);
      backend.emit(const StateEvent(RoomSnapshot()));
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.tabLibrary).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.likedSongs).last);
      await tester.pumpAndSettle();
      final title = tester.getTopLeft(find.text(S.likedSongs).last);
      expect(title.dx, greaterThanOrEqualTo(20 + 96), reason: 'the title is beside the tile, not under it');
      expect(tester.getTopLeft(find.text(S.play)).dy, lessThan(260));
    });
  });

  testWidgets('the sheet of the reactions has no empty band above its grid', (tester) async {
    final (backend, room) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pumpAndSettle();
    showReactionPicker(tester.element(find.byType(HomeShell)), room);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ReactionShower)).height, lessThanOrEqualTo(80));
  });

  group('the "…" of an album', () {
    const album = CollectionPage(
      id: 'MPREb_a',
      title: 'An Album',
      kind: 'Album',
      owner: 'Zen',
      tracks: [MusicTrack(videoId: 'albumsong01', title: 'One', artist: 'Zen', durMs: 200000, isSong: true)],
    );

    Future<void> openAlbum(WidgetTester tester, double width) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.collectionResult = album;
      await resize(tester, width, 900);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      openCollection(tester.element(find.byType(HomeShell)), id: 'MPREb_a', title: 'An Album');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.showMore));
      await tester.pumpAndSettle();
    }

    testWidgets('is a sheet from the bottom on a phone, with the album at its head', (tester) async {
      await openAlbum(tester, 411);
      expect(find.byType(ActionSheet), findsOneWidget);
      expect(find.byType(SheetHead), findsOneWidget);
      expect(find.text(S.addToQueue), findsOneWidget);
    });

    testWidgets('is the small menu where there is room, and not a sheet', (tester) async {
      await openAlbum(tester, 1280);
      expect(find.byType(ActionSheet), findsNothing);
      expect(find.text(S.addToQueue), findsOneWidget);
    });
  });
}
