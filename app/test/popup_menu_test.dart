import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// A wide window with a song playing, on the list of liked songs: the player bar floats over the foot of the page.
Future<FakeBackend> _likedWithPlayer(WidgetTester tester, {required int songs}) async {
  final (backend, _) = await pumpApp(
    tester,
    listen: false,
    prepare: (b) => b.likedSongs = [
      for (var i = 0; i < songs; i++)
        Track(videoId: 'liked$i' 'xxxxx', title: 'Liked $i', artist: 'Artist $i', durMs: 180000),
    ],
  );
  // After pumpApp, which sets a window of its own
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(1280, 800);
  backend.emit(StateEvent(sampleRoom()));
  backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  await tester.tap(find.text(S.tabLibrary).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(S.likedSongs).last);
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  group('the popup menu of a song on a wide window', () {
    testWidgets('has the song at its head', (tester) async {
      await _likedWithPlayer(tester, songs: 3);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).at(1));
      await tester.pumpAndSettle();
      expect(find.text(S.playNext), findsOneWidget);
      // The title is in the list and in the head of the menu
      expect(find.text('Liked 0'), findsNWidgets(2));
    });

    testWidgets('opens above the button, clear of the player bar, when it would reach it', (tester) async {
      await _likedWithPlayer(tester, songs: 14);
      final bar = tester.getRect(find.byType(PlayerBar));
      final rows = find.byIcon(Icons.more_horiz_rounded);
      // The last row that is on the page above the player bar
      final lowest = [
        for (var i = 1; i < rows.evaluate().length; i++) (i, tester.getCenter(rows.at(i)).dy),
      ].where((r) => r.$2 < bar.top).reduce((a, b) => a.$2 > b.$2 ? a : b);
      await tester.tap(rows.at(lowest.$1));
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.byType(Material).last);
      expect(menu.bottom, lessThanOrEqualTo(bar.top), reason: 'the menu is above the bar: $menu against $bar');
      expect(find.text(S.playNext), findsOneWidget);
    });
  });
}
