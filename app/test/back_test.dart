import 'package:flutter/material.dart' show TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/search_page.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// Back steps out one layer at a time, and leaves the app only from Home.
void main() {
  Future<void> back(WidgetTester tester, {required bool handled}) async {
    expect(await tester.binding.handlePopRoute(), handled);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'from the results of a search it takes three Backs to leave: the results, the tab, the app',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
      await tester.pump(const Duration(milliseconds: 500));
      backend.searchPageResult = const SearchResults(
        items: [SearchItem(kind: 'song', id: 'a', title: 'Found song')],
      );
      await tester.tap(find.byTooltip(S.tabSearch));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'found');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Found song'), findsOneWidget);
      expect(tester.widget<SearchPage>(find.byType(SearchPage)).back!.value, isTrue);

      // 1: the results go and the page is as it first was
      await back(tester, handled: true);
      expect(find.text('Found song'), findsNothing);
      expect(find.text(S.tabSearch), findsWidgets);
      expect(tester.widget<SearchPage>(find.byType(SearchPage)).back!.value, isFalse);

      // 2: to Home
      await back(tester, handled: true);
      expect(find.byType(SearchPage).hitTestable(), findsNothing);

      // 3: nothing is left to step out of: the system takes it
      await back(tester, handled: false);
    },
  );

  testWidgets('a tab other than Home goes back to Home before the app is left', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip(S.tabSearch));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage).hitTestable(), findsOneWidget);

    await back(tester, handled: true);
    expect(find.byType(SearchPage).hitTestable(), findsNothing);
    await back(tester, handled: false);
  });

  testWidgets('with lyrics shown it takes two Backs to close the player: the cover, then the player', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);

    await tester.tap(find.byTooltip(S.upNext));
    await tester.pumpAndSettle();
    expect(find.byTooltip(S.upNext), findsOneWidget);

    // 1: the queue goes, the player stays
    await back(tester, handled: true);
    expect(find.byType(NowPlayingPage).hitTestable(), findsOneWidget);
    expect(find.byType(MiniPlayer).hitTestable(), findsNothing);

    // 2: the player closes
    await back(tester, handled: true);
    expect(find.byType(MiniPlayer).hitTestable(), findsOneWidget);
  });
}
