import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/collection_screen.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/settings_page.dart';
import 'package:sapoche/ui/widgets/ambient_backdrop.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// A phone on its side, 844 by 390 dp, with a notch (or the system's bar) of [left] and [right] dp at the sides.
Future<(FakeBackend, BuildContext)> onItsSide(
  WidgetTester tester, {
  double left = 0,
  double right = 0,
}) async {
  final (backend, _) = await pumpApp(tester, listen: false);
  tester.view.physicalSize = const Size(1688, 780);
  final padding = FakeViewPadding(left: left * 2, right: right * 2);
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  backend.emit(StateEvent(sampleRoom()));
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  return (backend, tester.element(find.byType(HomeShell)));
}

void main() {
  const album = CollectionPage(
    id: 'MPREb_album',
    title: 'The Album',
    kind: 'Album',
    year: '2017',
    owner: 'Zen',
    stats: ['1 song'],
    tracks: [
      MusicTrack(
        videoId: 'a1aaaaaaaaa',
        title: 'One',
        artist: 'Zen',
        durMs: 200000,
      ),
    ],
  );

  for (final (name, left, right) in [
    ('on the left', 48.0, 0.0),
    ('on the right', 0.0, 48.0),
    ('at both sides', 40.0, 40.0),
  ]) {
    group('with a notch $name of a phone on its side', () {
      testWidgets('the rail and the mini player keep clear of it', (
        tester,
      ) async {
        await onItsSide(tester, left: left, right: right);
        for (final name in [
          S.tabHome,
          S.tabSearch,
          S.tabLibrary,
          S.tabListen,
        ]) {
          expect(
            tester.getRect(find.byTooltip(name)).left,
            greaterThanOrEqualTo(left),
          );
        }
        final mini = tester.getRect(find.byType(HomeShell).first);
        expect(mini.left, 0);
        expect(mini.right, 844);
        expect(
          tester.getRect(find.byTooltip(S.settingsTitle).first).right,
          lessThanOrEqualTo(844 - right),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'an album paints its backdrop under it and keeps its content clear',
        (tester) async {
          final (backend, context) = await onItsSide(
            tester,
            left: left,
            right: right,
          );
          backend.collectionResult = album;
          openCollection(context, id: 'MPREb_album', title: 'Placeholder');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // The picture behind it fills the window, the notch included
          final backdrop = tester.getRect(find.byType(PlayerBackdrop));
          expect(backdrop.left, 0);
          expect(backdrop.right, 844);
          // And the words and the buttons are beside the notch, not under it
          expect(
            tester.getRect(find.byTooltip('Back')).left,
            greaterThanOrEqualTo(left),
          );
          expect(
            tester.getRect(find.text('One')).right,
            lessThanOrEqualTo(844 - right),
          );
        },
      );

      testWidgets('the settings do the same', (tester) async {
        final (_, context) = await onItsSide(tester, left: left, right: right);
        openSettings(context);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final backdrop = tester.getRect(find.byType(AmbientBackdrop).last);
        expect(backdrop.left, 0);
        expect(backdrop.right, 844);
        expect(
          tester.getRect(find.text('Settings').first).left,
          greaterThanOrEqualTo(left),
        );
      });
    });
  }
}
