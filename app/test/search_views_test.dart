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

  testWidgets('a count is whole or left out, never cut; the name is cut last', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await search(tester, backend);

    // On a narrow phone, with a font twice as wide as the real one, the line of a long name has no room for the count: it
    // goes, whole, and the name is what is cut. A count in half ("270M vi…") or beside a name cut short is what is not
    // wanted.
    final lines = [for (final e in find.byType(Text).evaluate()) ?(e.widget as Text).data];
    for (final line in lines) {
      expect(line, isNot(matches(r'\d[MK]$')), reason: 'a count without its word: $line');
    }
    expect(find.textContaining('270M views'), findsNothing, reason: 'no room next to that name');
    for (final count in ['155M plays', '1.2M views']) {
      expect(find.textContaining(count), findsNothing, reason: count);
    }
    // What stays is the name, cut at its end if it must be
    expect(find.textContaining('Anna'), findsWidgets);
    // The likes are not shown, and an album with no count is as it was
    expect(find.textContaining('likes'), findsNothing);
    expect(find.text('Album · Anna · 2020'), findsOneWidget);
  });

  testWidgets('a count is there whole beside a name that fits, on a window as wide as the line needs', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await search(tester, backend, width: 1500);
    for (final count in ['270M views', '155M plays', '1.2M views']) {
      expect(find.textContaining(count), findsOneWidget, reason: count);
    }
  });

  testWidgets('says the count in Vietnamese when the app is', (tester) async {
    final (backend, _) = await pumpApp(tester);
    S.current = 'vi';
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await search(tester, backend, width: 1500);
    expect(find.textContaining('270 Tr lượt xem'), findsOneWidget);
    expect(find.textContaining('155 Tr lượt phát'), findsOneWidget);
  });
}
