import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unison/app.dart';
import 'package:unison/data/app_settings.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/room_controller.dart';
import 'package:unison/ui/now_playing_page.dart';
import 'package:unison/ui/scope.dart';
import 'package:unison/ui/widgets/shimmer.dart';
import 'package:unison/ui/widgets/mini_player.dart';

import 'fake_backend.dart';

Future<(FakeBackend, RoomController)> pumpApp(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
}) async {
  // A tall phone-shaped window; the default 800x600 one is not what the app runs on. Test text is
  // drawn with the wide Ahem font, so it is 540 dp wide instead of the usual 360 to avoid false overflows.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'theme_mode': mode.name});
  final backend = FakeBackend();
  final room = RoomController(backend);
  final settings = await AppSettings.load();
  await tester.pumpWidget(
    UnisonApp(
      model: AppModel(room: room, settings: settings),
    ),
  );
  await room.start();
  return (backend, room);
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    group('in ${mode.name} mode', () {
      testWidgets('welcome screen creates a room with the typed name', (
        tester,
      ) async {
        final (backend, _) = await pumpApp(tester, mode: mode);
        backend.emit(const StateEvent(RoomSnapshot()));
        // The logo pulses forever, so the tree never settles
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.text('Create a room'), findsOneWidget);
        expect(
          find.text('Anna'),
          findsOneWidget,
          reason: 'the saved name is prefilled',
        );

        await tester.tap(find.text('Create a room'));
        await tester.pump();
        expect(backend.calls, contains('createRoom Anna'));
      });

      testWidgets('an empty room invites the user to add songs', (
        tester,
      ) async {
        final (backend, _) = await pumpApp(tester, mode: mode);
        backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
        await tester.pumpAndSettle();

        expect(find.text('Nothing queued yet'), findsOneWidget);
        expect(find.text('ABC234'), findsOneWidget);
        await tester.tap(find.text('Add songs'));
        await tester.pumpAndSettle();
        expect(find.text('Find something to play'), findsOneWidget);
      });

      testWidgets(
        'shows the queue and the mini player, and the full player opens',
        (tester) async {
          final (backend, _) = await pumpApp(tester, mode: mode);
          backend.emit(StateEvent(sampleRoom()));
          backend.emit(
            const PositionEvent(
              PlayerPosition(
                playing: true,
                positionMs: 4000,
                durationMs: 200000,
                driftMs: 12,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 500));

          expect(find.text('Up Next'), findsOneWidget);
          expect(find.text('Song 1'), findsOneWidget);

          // Mini player is the only place the title appears twice with the queue row
          await tester.tap(find.byIcon(Icons.pause_rounded));
          await tester.pump();
          expect(backend.calls.last, 'pause');

          await tester.tap(find.byType(MiniPlayer));
          await tester.pump(); // the route is built offstage first
          await tester.pump(const Duration(milliseconds: 700));
          expect(find.textContaining('In sync'), findsOneWidget);
        },
      );

      testWidgets('leaving the room from settings asks first', (tester) async {
        final (backend, _) = await pumpApp(tester, mode: mode);
        backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Leave room'));
        await tester.pumpAndSettle();
        expect(
          find.text('Leave this room? You can join again with the code.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Leave'));
        await tester.pumpAndSettle();
        expect(backend.calls, contains('leave'));
      });
    });
  }

  testWidgets('pasting a playlist link offers to add every song', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    backend.lookupResult = const LinkResult(
      playlistTitle: 'Road trip',
      tracks: [
        Track(videoId: 'aaaaaaaaaaa', title: 'First', artist: 'x', durMs: 1000),
        Track(
          videoId: 'bbbbbbbbbbb',
          title: 'Second',
          artist: 'x',
          durMs: 1000,
        ),
      ],
    );

    await tester.tap(find.text('Search'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/playlist?list=PLabcdefghijk',
    );
    await tester.pump(const Duration(milliseconds: 600)); // debounce
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Road trip'), findsOneWidget);
    expect(find.text('Playlist · 2 songs'), findsOneWidget);
    await tester.tap(find.text('Add all'));
    await tester.pump();
    expect(backend.calls.last, 'addMany aaaaaaaaaaa,bbbbbbbbbbb next=false');
    await tester.pump(
      const Duration(seconds: 3),
    ); // let the confirmation timers finish
  });

  testWidgets('the repeat button on the full player asks for the next mode', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.pump();
    expect(backend.calls.last, 'repeat all');

    backend.emit(StateEvent(sampleRoom(repeat: Repeat.one)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.repeat_one_rounded), findsOneWidget);
  });

  testWidgets('an invitation link opens the join sheet with its code', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pump(const Duration(milliseconds: 500));

    backend.emit(const InviteEvent('K2A5RF'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500)); // the sheet slides in
    expect(find.text('K2A5RF'), findsOneWidget);

    await tester.tap(find.text('Join').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.calls.last, 'join K2A5RF Anna');
  });

  testWidgets('an invitation to another room asks before switching', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));

    backend.emit(const InviteEvent('ZZZ999'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Leave this room and join ZZZ999?'), findsOneWidget);
    await tester.tap(find.text('Join'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.calls.last, 'join ZZZ999 Anna');
  });

  testWidgets('the same room in an invitation does nothing', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    backend.emit(const InviteEvent('ABC234'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Switch room'), findsNothing);
  });

  testWidgets('the name can be changed from settings', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Your name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Anh');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'rename Anh');
  });

  testWidgets('pulling the full player down closes it', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(NowPlayingPage), findsOneWidget);

    // Slow and short: it springs back (a quick flick of any length would count as a fling)
    await tester.timedDrag(
      find.byType(NowPlayingPage),
      const Offset(0, 120),
      const Duration(seconds: 2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsOneWidget);

    // Far enough: it flies off, then the route pops
    await tester.drag(
      find.byType(NowPlayingPage),
      const Offset(0, 700),
      warnIfMissed: false,
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsNothing);
  });

  testWidgets('a new song slides in but the ones already there do not', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 3)));
    await tester.pump(const Duration(milliseconds: 100));
    // Songs that were there from the start are fully visible at once
    expect(
      tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.text('Song 1'),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value,
      1,
    );

    backend.emit(StateEvent(sampleRoom(songs: 4)));
    await tester.pump(const Duration(milliseconds: 50));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Song 3'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 600));
    expect(fade.opacity.value, 1);
  });

  testWidgets('a search shows placeholder rows while it loads', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    backend.searchGate = Completer<void>();
    await tester.tap(find.text('Search'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump(
      const Duration(milliseconds: 500),
    ); // the search starts after a short pause
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SkeletonList), findsOneWidget);
    backend.searchGate!.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SkeletonList), findsNothing);
  });

  testWidgets('the player only says in sync when the drift is small', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    backend.emit(
      const PositionEvent(
        PlayerPosition(
          playing: true,
          positionMs: 4000,
          durationMs: 200000,
          driftMs: 250,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.textContaining('Catching up'), findsOneWidget);
    expect(find.textContaining('In sync'), findsNothing);

    backend.emit(
      const PositionEvent(
        PlayerPosition(
          playing: true,
          positionMs: 5000,
          durationMs: 200000,
          driftMs: -30,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('In sync'), findsOneWidget);
  });
}
