import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

void main() {
  tearDown(() => S.current = 'en');

  Future<void> search(WidgetTester tester, FakeBackend backend, {double width = 360}) async {
    // A narrow phone, the width the count must still fit on (the font of a test is twice as wide as a real one)
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    backend.searchPageResult = const SearchResults(
      items: [
        SearchItem(
          kind: 'video',
          id: 'vvvvvvvvvvv',
          title: 'Lac Troi',
          track: MusicTrack(
            videoId: 'vvvvvvvvvvv',
            title: 'Lac Troi',
            artist: 'Son Tung M-TP the singer with a very long name',
            durMs: 1000,
            stats: '270M views · 2M likes',
          ),
        ),
        SearchItem(
          kind: 'song',
          id: 'sssssssssss',
          title: 'A Song',
          track: MusicTrack(
            videoId: 'sssssssssss',
            title: 'A Song',
            artist: 'Anna',
            durMs: 1000,
            stats: '155M plays',
            isSong: true,
          ),
        ),
        SearchItem(
          kind: 'playlist',
          id: 'VLPLx',
          title: 'Best of the year',
          subtitle: 'A playlist by someone with a long name · 1.2M views',
          label: 'Playlist',
        ),
        SearchItem(
          kind: 'album',
          id: 'MPREb_x',
          title: 'An Album',
          subtitle: 'Anna · 2020',
          label: 'Album',
        ),
      ],
    );
    await tester.tap(find.byTooltip(S.tabSearch));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lac');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('a count is not cut on a narrow phone, the name is', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await search(tester, backend);

    for (final count in ['270M views', '155M plays', '1.2M views']) {
      expect(find.textContaining(count), findsOneWidget, reason: count);
      final text = tester.widget<Text>(find.textContaining(count));
      expect(text.overflow, isNot(TextOverflow.ellipsis), reason: count);
      expect(tester.getRect(find.textContaining(count)).right, lessThanOrEqualTo(360 - 20 - 48), reason: count);
    }
    // The likes are not shown, and an album with no count is as it was
    expect(find.textContaining('likes'), findsNothing);
    expect(find.text('Album · Anna · 2020'), findsOneWidget);
  });

  testWidgets('says the count in Vietnamese when the app is', (tester) async {
    final (backend, _) = await pumpApp(tester);
    S.current = 'vi';
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await search(tester, backend, width: 720);
    expect(find.textContaining('270 Tr lượt xem'), findsOneWidget);
    expect(find.textContaining('155 Tr lượt phát'), findsOneWidget);
    expect(find.textContaining('1,2 Tr lượt xem'), findsOneWidget);
  });
}
