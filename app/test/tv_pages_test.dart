import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/ui/artist_page.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';

import 'tv_test.dart' show pumpTv, press, unreachable;

MusicTrack song(int i) => MusicTrack(
  videoId: 'v${i.toString().padLeft(10, '0')}',
  title: 'Song $i',
  artist: 'Zen',
  durMs: 200000,
  isSong: true,
  stats: '${i}M plays',
);

bool _alive(FocusNode node) {
  try {
    node.rect;
    return true;
  } catch (_) {
    return false;
  }
}

/// Presses OK on each control of what is on the screen and, whatever opens (a page, a sheet, a dialog), walks that with
/// the arrows too, then goes back. Returns what was not reached, with where it was. [skip] is for controls that
/// would leave the screen for good.
Future<List<String>> openEverything(
  WidgetTester tester, {
  Set<String> skip = const {},
}) async {
  final problems = <String>[];
  final walked = <String>{};
  final here = FocusManager.instance.rootScope.descendants
      .where(
        (n) =>
            n is! FocusScopeNode &&
            n.canRequestFocus &&
            !n.skipTraversal &&
            (n.context?.mounted ?? false) &&
            _alive(n) &&
            // The page, not the rail or the bar of the player (their own tests walk them)
            n.rect.left > 200 &&
            n.rect.top < 900 &&
            // Not what lies under a page that another covers
            !n.ancestors.any(
              (a) =>
                  a is FocusScopeNode &&
                  a.skipTraversal &&
                  (a.debugLabel?.contains('_ModalScopeState') ?? false),
            ),
      )
      .toList();
  for (final node in here) {
    if (!(node.context?.mounted ?? false) || !node.canRequestFocus) continue;
    final route = ModalRoute.of(node.context!);
    Rect where;
    try {
      where = node.rect;
    } catch (_) {
      continue; // gone with the page an earlier OK closed
    }
    node.requestFocus();
    await tester.pump(const Duration(milliseconds: 100));
    await press(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    // What went away is gone before what is there is counted
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
    } catch (_) {}
    final now = FocusManager.instance.primaryFocus?.context;
    final opened = now != null && now.mounted ? ModalRoute.of(now) : null;
    if (opened != null && !identical(opened, route)) {
      final scope = FocusManager.instance.primaryFocus?.nearestScope;
      final kids = scope?.traversalDescendants.length ?? 0;
      final signature = '${opened.runtimeType} $kids';
      if (kids > 0 && walked.add(signature)) {
        // Of what the new page holds (the rail and the bar beside it are walked by the tests of the screens)
        final route = FocusManager.instance.primaryFocus?.nearestScope;
        for (final lost in await unreachable(
          tester,
          only: (n) => route != null && n.ancestors.contains(route),
        )) {
          problems.add('after OK on $where: $lost');
        }
      }
      for (var i = 0; i < 4 && (route != null && !route.isCurrent); i++) {
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 600));
      }
    }
  }
  return problems;
}

/// Pages that a person is taken to from the home screens, walked by a remote as the others are: every control on them
/// has to be reached with the four arrows.
void main() {
  group('a remote reaches every control on', () {
    testWidgets('an album', (tester) async {
      final backend = await pumpTv(tester);
      backend.collectionResult = CollectionPage(
        id: 'MPREb_album',
        title: 'The Album',
        kind: 'Album',
        year: '2017',
        owner: 'Zen',
        ownerId: 'UCzen',
        description: 'Made in a hurry. ' * 8,
        stats: const ['6 songs', '20 minutes'],
        tracks: [for (var i = 1; i <= 6; i++) song(i)],
        shelves: const [
          MusicShelf(
            title: 'More by Zen',
            albums: [
              Release(id: 'MPREb_other', title: 'Other Album'),
              Release(id: 'MPREb_third', title: 'Third Album'),
            ],
          ),
        ],
      );
      final context = tester.element(find.byType(HomeShell));
      openCollection(context, id: 'MPREb_album', title: 'The Album');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Song 3'), findsOneWidget);
      // The focus went to the page that opened, not on staying with what is under it
      final on = FocusManager.instance.primaryFocus;
      expect(on, isNot(isA<FocusScopeNode>()));
      expect(ModalRoute.of(on!.context!)?.isCurrent, isTrue);
      expect(await unreachable(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a playlist with a long list of songs', (tester) async {
      final backend = await pumpTv(tester);
      backend.collectionResult = CollectionPage(
        id: 'VLPL1',
        title: 'The Playlist',
        kind: 'Playlist',
        owner: 'Zen',
        ownerId: 'UCzen',
        stats: const ['40 songs'],
        tracks: [for (var i = 1; i <= 40; i++) song(i)],
      );
      final context = tester.element(find.byType(HomeShell));
      openCollection(context, id: 'VLPL1', title: 'The Playlist');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Song 1'), findsOneWidget);
      // Page Down and Channel + scroll the page by most of a screen, and back up again
      double offset() => [
        for (final e
            in find
                .descendant(
                  of: find.byType(CollectionScreen),
                  matching: find.byType(Scrollable),
                )
                .evaluate())
          ((e as StatefulElement).state as ScrollableState).position,
      ].firstWhere((p) => p.maxScrollExtent > 0).pixels;
      expect(offset(), 0);
      await press(tester, LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 600));
      final down = offset();
      expect(down, greaterThan(300));
      await press(tester, LogicalKeyboardKey.channelUp);
      await tester.pump(const Duration(milliseconds: 600));
      expect(offset(), lessThan(down));
      expect(await unreachable(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an artist', (tester) async {
      final backend = await pumpTv(tester);
      backend.artistResult = ArtistPage(
        id: 'UCzen',
        name: 'Zen',
        description: 'Makes music. ' * 10,
        subscribers: '1.2M subscribers',
        topSongs: [for (var i = 1; i <= 5; i++) song(i)],
        albums: const [
          Release(id: 'MPREb_a1', title: 'First Album'),
          Release(id: 'MPREb_a2', title: 'Second Album'),
        ],
        singles: const [Release(id: 'MPREb_s1', title: 'A Single')],
        similar: const [
          ArtistCard(id: 'UCone', name: 'One'),
          ArtistCard(id: 'UCtwo', name: 'Two'),
        ],
      );
      final context = tester.element(find.byType(HomeShell));
      unawaited(openArtist(context, 'UCzen'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Zen'), findsWidgets);
      expect(await unreachable(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('whatever opens from', () {
    testWidgets('the settings is reached by the arrows', (tester) async {
      await pumpTv(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(await openEverything(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the library is reached by the arrows', (tester) async {
      await pumpTv(tester);
      await tester.tap(find.byIcon(Icons.library_music_rounded).first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(await openEverything(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the home is reached by the arrows', (tester) async {
      await pumpTv(tester);
      expect(await openEverything(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
