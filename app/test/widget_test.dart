import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/ui/now_playing_page.dart';
import 'package:unison/ui/setup_dialog.dart';
import 'package:unison/ui/widgets/qr_code_view.dart';
import 'package:unison/ui/widgets/shimmer.dart';
import 'package:unison/ui/widgets/mini_player.dart';
import 'package:unison/ui/widgets/track_menu.dart';
import 'package:unison/ui/widgets/track_tile.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    group('in ${mode.name} mode', () {
      testWidgets(
        'the app opens outside a room, and the room sheet creates one with the typed name',
        (tester) async {
          final (backend, _) = await pumpApp(tester, mode: mode);
          backend.emit(const StateEvent(RoomSnapshot()));
          await tester.pumpAndSettle();

          expect(find.text('Nothing queued yet'), findsOneWidget);
          expect(
            find.text('Search for a song and add it to start listening.'),
            findsOneWidget,
            reason: 'no talk of a room while there is none',
          );
          await tester.tap(find.text('Room'));
          await tester.pumpAndSettle();

          expect(find.text('Create a room'), findsOneWidget);
          expect(
            find.text('Anna'),
            findsOneWidget,
            reason: 'the saved name is prefilled',
          );
          await tester.tap(find.text('Create a room'));
          await tester.pumpAndSettle();
          expect(backend.calls, contains('createRoom Anna'));

          backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
          await tester.pumpAndSettle();
          expect(
            find.text('Scan to join'),
            findsOneWidget,
            reason: 'the sheet stays and shows how to invite people',
          );
        },
      );

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

        await openTopic(tester, 'room');
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

  testWidgets('the sleep timer is set from the full player and shown there', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.byTooltip('Sleep timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 minutes'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'sleep time 30');

    backend.emit(const SleepEvent(SleepState(mode: SleepMode.song)));
    await tester.pumpAndSettle();
    expect(find.text('Stops after this song'), findsOneWidget);

    await tester.tap(find.text('Stops after this song'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off timer'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'sleep off 0');
  });

  testWidgets(
    'an invitation link goes into its room with the name of this phone',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();

      backend.emit(const InviteEvent('K2A5RF'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'join K2A5RF Anna');
      expect(find.text('Enter your name first'), findsNothing);
    },
  );

  testWidgets(
    'an invitation that finds no name waits for one instead of being lost',
    (tester) async {
      final (backend, _) = await pumpApp(tester, profile: const Profile());
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();

      backend.emit(const InviteEvent('K2A5RF'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your name first'), findsOneWidget);
      expect(backend.calls.where((c) => c.startsWith('join')), isEmpty);

      await tester.enterText(find.byType(TextField), 'Hana');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        backend.calls.last,
        'join K2A5RF Hana',
        reason: 'the link is not followed twice',
      );
    },
  );

  testWidgets(
    'the code of a waiting invitation is offered when joining by hand',
    (tester) async {
      final (backend, _) = await pumpApp(tester, profile: const Profile());
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      backend.emit(const InviteEvent('K2A5RF'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Hana');
      await tester.tap(find.text('Join a room'));
      await tester.pumpAndSettle();
      expect(find.text('K2A5RF'), findsOneWidget);
      await tester.tap(find.text('Join').last);
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'join K2A5RF Hana');
    },
  );

  testWidgets(
    'a personal queue looks like a room queue without the room parts',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          RoomSnapshot(
            phase: 'paused',
            queue: [
              for (var i = 0; i < 3; i++)
                QueueEntry(
                  id: 'q$i',
                  videoId: 'video$i',
                  title: 'Song $i',
                  artist: 'Artist $i',
                  durMs: 200000,
                  addedBy: '',
                ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Song 0'), findsWidgets);
      expect(find.text('Song 2'), findsOneWidget);
      expect(find.text('Room'), findsOneWidget, reason: 'the way into a room');
      expect(find.textContaining('listening'), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
      await tester.pump();
      expect(backend.calls.last, 'play');
    },
  );

  testWidgets('settings are a short list, and every topic has a page', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pumpAndSettle();
    await openSettingsList(tester);

    // Who this is and where, then one row per topic, and nothing of the topics themselves
    expect(find.text('Anna'), findsWidgets);
    expect(find.text('Room ABC234 · 2 people listening'), findsOneWidget);
    for (final topic in [
      'appearance',
      'playback',
      'room',
      'storage',
      'backup',
    ]) {
      expect(find.byKey(ValueKey('settings-$topic')), findsOneWidget);
    }
    expect(find.text('Played songs'), findsNothing);
    expect(find.text('Autoplay'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-playback')));
    await tester.pumpAndSettle();
    expect(find.text('Autoplay'), findsWidgets);
    expect(find.text('Latency trim'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-playback')), findsOneWidget);
  });

  testWidgets('the room page closes itself once the room is left', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pumpAndSettle();
    await openTopic(tester, 'room');
    expect(find.text('Leave room'), findsOneWidget);

    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    expect(find.text('Leave room'), findsNothing);
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-room')), findsNothing);
  });

  testWidgets('settings have no room section outside a room', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await openSettingsList(tester);
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-room')), findsNothing);
  });

  testWidgets(
    'recent rooms are listed with who is there, and one is joined with a tap',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final (backend, _) = await pumpApp(
        tester,
        prefs: {
          'recent_rooms': '[{"code":"K2A5RF","name":"Family","at":$now}]',
        },
      );
      backend.roomInfoResult = const RoomInfo(
        exists: true,
        name: 'Family',
        members: 2,
      );
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Room'));
      await tester.pumpAndSettle();

      expect(find.text('Recent rooms'), findsOneWidget);
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('K2A5RF · 2 listening'), findsOneWidget);
      expect(backend.calls, contains('roomInfo K2A5RF'));

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'join K2A5RF Anna');
      expect(
        find.text('Recent rooms'),
        findsNothing,
        reason: 'joining closes the sheet',
      );
    },
  );

  testWidgets('joining closes the sheet even when the room arrives first', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final (backend, _) = await pumpApp(
      tester,
      prefs: {'recent_rooms': '[{"code":"ABC234","name":null,"at":$now}]'},
    );
    backend.roomInfoResult = const RoomInfo(exists: true, members: 1);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1 listening'));
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pumpAndSettle();
    expect(
      find.text('Scan to join'),
      findsNothing,
      reason: 'no invitation panel after joining a room',
    );
    expect(find.text('ABC234'), findsOneWidget, reason: 'the room page shows');
  });

  testWidgets('a room that no longer exists is marked and cannot be joined', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final (backend, _) = await pumpApp(
      tester,
      prefs: {'recent_rooms': '[{"code":"K2A5RF","name":null,"at":$now}]'},
    );
    backend.roomInfoResult = const RoomInfo(exists: false);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();

    expect(find.text('Expired'), findsOneWidget);
    await tester.tap(find.text('Expired'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.startsWith('join')), isEmpty);

    await tester.tap(find.byTooltip('Forget this room'));
    await tester.pumpAndSettle();
    expect(find.text('Recent rooms'), findsNothing);
  });

  testWidgets('a name is needed before starting a room', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Create a room'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your name first'), findsOneWidget);
    expect(backend.calls.where((c) => c.startsWith('createRoom')), isEmpty);
  });

  testWidgets(
    'the room sheet in a room shows the code, the link and lets the owner limit guests',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            name: 'Family',
            ownerId: 'me',
            members: const [
              Member(id: 'me', name: 'Anna', ready: true, owner: true),
              Member(id: 'b', name: 'Binh', ready: true),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Family'),
        findsOneWidget,
        reason: 'the room name is the title',
      );

      await tester.tap(find.byTooltip('Room'));
      await tester.pumpAndSettle();
      expect(find.text('Scan to join'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'guestControl add');

      await tester.tap(find.byTooltip('Room name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Weekend');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'roomName Weekend');
    },
  );

  testWidgets(
    'a guest does not get the owner switch, and is told when guests may only add songs',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            ownerId: 'b',
            guestControl: GuestControl.add,
            members: const [
              Member(id: 'me', name: 'Anna', ready: true),
              Member(id: 'b', name: 'Binh', ready: true, owner: true),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The owner lets guests add songs only'), findsOneWidget);

      await tester.tap(find.byTooltip('Room'));
      await tester.pumpAndSettle();
      expect(find.text('Guests can only add songs'), findsNothing);
      expect(
        find.byTooltip('Room name'),
        findsNothing,
        reason: 'a guest cannot rename a restricted room',
      );
    },
  );

  testWidgets(
    'with the owner away a restricted room is open to everyone again',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            ownerId: 'b',
            guestControl: GuestControl.add,
            members: const [Member(id: 'me', name: 'Anna', ready: true)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The owner lets guests add songs only'), findsNothing);
    },
  );

  testWidgets('the owner can remove a member from the list of people', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(
      StateEvent(
        sampleRoom(
          ownerId: 'me',
          members: const [
            Member(id: 'me', name: 'Anna', ready: true, owner: true),
            Member(id: 'b', name: 'Binh', ready: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 people listening'));
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('Remove from room'),
      findsOneWidget,
      reason: 'not for the owner themself',
    );
    await tester.tap(find.byTooltip('Remove from room'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Remove Binh from the room? They can join again with the code.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'kick b');
  });

  testWidgets('a guest sees no way to remove anyone', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(
      StateEvent(
        sampleRoom(
          ownerId: 'b',
          members: const [
            Member(id: 'me', name: 'Anna', ready: true),
            Member(id: 'b', name: 'Binh', ready: true, owner: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 people listening'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from room'), findsNothing);
    expect(
      find.byIcon(Icons.workspace_premium_rounded),
      findsOneWidget,
      reason: 'the owner wears a mark',
    );
  });

  testWidgets('an invitation to another room asks before switching', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    backend.emit(const InviteEvent('ZZZ999'));
    await tester.pump(const Duration(milliseconds: 500));
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
    await tester.pump(const Duration(milliseconds: 500));
    backend.emit(const InviteEvent('ABC234'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Switch room'), findsNothing);
  });

  testWidgets('the name can be changed from settings', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await openTopic(tester, 'room');
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

    // Far enough: the sheet carries on down on its own and the route pops
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

  testWidgets('dragging the mini player up pulls the full player open', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MiniPlayer)),
    );
    // The first move only makes Flutter recognise a drag; the ones after it move the sheet
    await gesture.moveBy(const Offset(0, -50));
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    // Held part way: the screen behind must still be there, not a black gap
    expect(find.byType(MiniPlayer), findsOneWidget);
    final top = tester.getTopLeft(find.byType(NowPlayingPage)).dy;
    expect(top, greaterThan(0));

    await gesture.moveBy(const Offset(0, -500));
    await gesture.up();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(tester.getTopLeft(find.byType(NowPlayingPage)).dy, 0);
  });

  testWidgets('a setup link that is opened asks before it sets the server', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(
      const SetupEvent(
        'unison://setup?server=https%3A%2F%2Funison.example.dev&key=k3y',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use this server?'), findsOneWidget);
    expect(find.textContaining('unison.example.dev'), findsOneWidget);
    expect(backend.calls.where((c) => c.startsWith('configure')), isEmpty);

    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('configure https://unison.example.dev k3y'));
    expect(find.text('Server set'), findsOneWidget);
  });

  testWidgets('saying no to a setup link sets nothing', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(
      const SetupEvent('unison://setup?server=https://evil.example&key=k'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.startsWith('configure')), isEmpty);
  });

  testWidgets('the phone with the server shows it as a code for another', (
    tester,
  ) async {
    final (backend, room) = await pumpApp(tester);
    backend.setupLinkValue =
        'unison://setup?server=https%3A%2F%2Fa.example&key=k';
    showSetupLinkDialog(tester.element(find.byType(Scaffold).first), room);
    await tester.pumpAndSettle();
    expect(find.byType(QrCodeView), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
  });

  testWidgets('a phone with no server has nothing to show', (tester) async {
    final (_, room) = await pumpApp(tester);
    showSetupLinkDialog(tester.element(find.byType(Scaffold).first), room);
    await tester.pumpAndSettle();
    expect(find.byType(QrCodeView), findsNothing);
    expect(find.text('This phone has no server to share'), findsOneWidget);
  });

  testWidgets('the player grows out of the mini player under the finger', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final miniTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MiniPlayer)),
    );
    // Every pixel the finger has moved, the sheet's top edge has moved with it: it began at the mini player
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      tester.getTopLeft(find.byType(NowPlayingPage)).dy,
      closeTo(miniTop - 40, 1),
    );
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      tester.getTopLeft(find.byType(NowPlayingPage)).dy,
      closeTo(miniTop - 240, 1),
    );
    // Let go below the half way: it goes back into the mini player
    await gesture.up();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsNothing);
  });

  testWidgets(
    'tapping who is here lists the members and offers to listen alone',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            members: const [
              Member(id: 'me', name: 'Anna', ready: true),
              Member(id: 'b', name: 'Binh', ready: true, solo: true),
              Member(id: 'c', name: 'Chi', ready: false, away: true),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('2 people listening · 1 away'), findsOneWidget);

      await tester.tap(find.text('2 people listening · 1 away'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('In the room'), findsOneWidget);
      expect(find.text('Anna (You)'), findsOneWidget);
      expect(find.text('On their own'), findsOneWidget);
      expect(find.text('Connection lost'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(backend.calls.last, 'solo true');
    },
  );

  testWidgets('listening alone shows a banner with the way back', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(solo: true, soloItemId: 'q1')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('You are listening on your own'), findsOneWidget);
    expect(
      find.textContaining('On your own'),
      findsWidgets,
      reason: 'the mini player says so too',
    );

    await tester.tap(find.text('Rejoin'));
    await tester.pump();
    expect(backend.calls.last, 'solo false');
  });

  testWidgets(
    'when someone pauses the room, a snackbar offers to keep playing',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      backend.emit(const NoticeEvent(kind: 'paused', by: 'Binh'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Binh paused the room'), findsOneWidget);

      await tester.tap(find.text('Keep playing'));
      await tester.pump();
      expect(backend.calls, contains('keepPlaying'));
    },
  );

  testWidgets(
    'the player switches between audio and video, and only asks for the picture while showing it',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(MiniPlayer));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Texture), findsNothing);
      expect(backend.calls, isNot(contains('videoSurface')));

      await tester.tap(find.text('Video'));
      await tester.pump();
      expect(backend.calls, contains('video true'));

      // The native side reports the mode back, and the picture view takes the cover's place
      backend.emit(StateEvent(sampleRoom(video: true)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        backend.calls,
        containsAllInOrder(['videoVisible true', 'videoSurface']),
      );
      expect(find.byType(Texture), findsNothing, reason: 'no frame yet');

      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, videoWidth: 1280, videoHeight: 720),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Texture), findsOneWidget);

      // Closing the player stops the picture from being fetched
      await tester.binding.handlePopRoute();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(backend.calls.last, 'videoVisible false');
    },
  );

  testWidgets('search can be narrowed to songs and looks again', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'lofi');
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.calls.last, 'search lofi');

    await tester.tap(find.text('Songs'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.calls.last, 'search lofi songs');
  });

  testWidgets('a song that is queued already cannot be added from search', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 3)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // Song 1 is waiting in the queue; "Fresh song" is not
    backend.searchResults = const [
      Track(
        videoId: 'video1',
        title: 'Song 1',
        artist: 'Artist 1',
        durMs: 1000,
      ),
      Track(videoId: 'fresh', title: 'Fresh song', artist: 'x', durMs: 1000),
    ];
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'song');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));

    // In a room a touch queues the song
    await tester.tap(find.widgetWithText(TrackTile, 'Song 1'));
    await tester.pump();
    expect(find.text('Already in the queue'), findsOneWidget);
    expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);

    await tester.tap(find.widgetWithText(TrackTile, 'Fresh song'));
    await tester.pump();
    expect(backend.calls.last, 'add fresh next=false');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'a touch on a result outside a room plays it, and its radio fills the queue',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const StateEvent(RoomSnapshot()));
      backend.searchResults = const [
        Track(videoId: 'aaaaaaaaaaa', title: 'Found', artist: 'x', durMs: 1000),
      ];
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'found');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));

      // The plus is gone: a touch plays, the menu holds the rest
      expect(find.byIcon(Icons.add_rounded), findsNothing);
      await tester.tap(find.widgetWithText(TrackTile, 'Found'));
      await tester.pump();
      expect(
        backend.calls,
        containsAllInOrder([
          'clear',
          'addMany aaaaaaaaaaa next=false',
          'radio aaaaaaaaaaa',
        ]),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a touch on a song of a playlist result plays from there', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
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
        Track(videoId: 'ccccccccccc', title: 'Third', artist: 'x', durMs: 1000),
      ],
    );
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/playlist?list=PLroadtrip',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.widgetWithText(TrackTile, 'Second'));
    await tester.pump();
    expect(
      backend.calls,
      containsAllInOrder([
        'clear',
        'addMany bbbbbbbbbbb,ccccccccccc next=false',
      ]),
    );
    expect(backend.calls.where((c) => c.startsWith('radio')), isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'searching playlists lists them, and one can be opened and left again',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      backend.playlistResults = const [
        PlaylistRef(
          id: 'PLroadtrip',
          title: 'Road trip',
          uploader: 'Anna',
          count: 12,
        ),
      ];
      backend.lookupResult = const LinkResult(
        playlistTitle: 'Road trip',
        tracks: [
          Track(
            videoId: 'aaaaaaaaaaa',
            title: 'First',
            artist: 'x',
            durMs: 1000,
          ),
        ],
      );
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playlists'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'road');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls, contains('searchPlaylists road'));
      expect(find.text('Road trip'), findsOneWidget);
      expect(find.text('Anna · 12 songs'), findsOneWidget);

      await tester.tap(find.text('Road trip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        backend.calls,
        contains('lookup https://www.youtube.com/playlist?list=PLroadtrip'),
      );
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Add all'), findsOneWidget);

      await tester.tap(find.text('All playlists'));
      await tester.pump(const Duration(milliseconds: 400));
      // A cross-fade starts on the frame after the change, then needs its own time to end
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Road trip'), findsOneWidget);
      expect(find.text('First'), findsNothing);
    },
  );

  testWidgets('the shuffle button mixes up what is to come', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 4)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Shuffle'));
    await tester.pump();
    expect(backend.calls.last, 'shuffle');
  });

  testWidgets(
    'a song that was already played can be swiped away, and tapped to hear it again',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(songs: 3, index: 2)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Song 0'));
      await tester.pump();
      expect(backend.calls.last, 'jump q0');

      await tester.drag(find.text('Song 1'), const Offset(-800, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(backend.calls.last, 'remove q1');
    },
  );

  testWidgets('the song that is playing can be swiped away too', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 3, index: 0)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // The mini player shows the title too; the queue row comes first
    await tester.drag(find.text('Song 0').first, const Offset(-800, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.calls.last, 'remove q0');
  });

  testWidgets('when the queue has finished, the room offers to play it again', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 3, index: 2, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('The queue has finished'), findsOneWidget);

    await tester.tap(find.text('Play again'));
    await tester.pump();
    expect(backend.calls.last, 'play');

    backend.emit(StateEvent(sampleRoom(songs: 3, index: 2)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('The queue has finished'), findsNothing);
  });

  testWidgets('Back closes the open player instead of leaving the app', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(MiniPlayer));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(find.byType(MiniPlayer), findsOneWidget);
  });

  testWidgets('a short slow drag on the mini player opens nothing', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.timedDrag(
      find.byType(MiniPlayer),
      const Offset(0, -100),
      const Duration(seconds: 2),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(find.byType(MiniPlayer), findsOneWidget);
  });

  testWidgets('a new song slides in but the ones already there do not', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester, listen: false);
    backend.emit(StateEvent(sampleRoom(songs: 3)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Listen'));
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
    await tester.pump(const Duration(milliseconds: 500));
    backend.searchGate = Completer<void>();
    await tester.tap(find.text('Search'));
    await tester.pump(const Duration(milliseconds: 500));
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

  testWidgets('music playing does not keep the screen redrawing every frame', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    backend.emit(
      const PositionEvent(
        PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
      ),
    );
    // pumpAndSettle only returns when no animation is running; a ticker left going by the
    // equalizer or the seek bar would make it time out, and would cost battery on the real phone
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);
  });

  group('the library', () {
    const songA = Track(
      videoId: 'aaaaaaaaaaa',
      title: 'Alpha',
      artist: 'Ann',
      durMs: 100000,
    );
    const songB = Track(
      videoId: 'bbbbbbbbbbb',
      title: 'Beta',
      artist: 'Ben',
      durMs: 100000,
    );

    Future<FakeBackend> openLibrary(WidgetTester tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.likedSongs = [songA, songB];
      backend.recentSongs = [
        HistoryEntry(
          track: songB,
          at: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      ];
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('lists its collections with their sizes', (tester) async {
      await openLibrary(tester);
      expect(find.text('Liked songs'), findsOneWidget);
      expect(find.text('2 songs'), findsOneWidget);
      expect(find.text('Recently played'), findsOneWidget);
      expect(find.text('1 song'), findsOneWidget);
    });

    testWidgets('play outside a room replaces the queue with the liked songs', (
      tester,
    ) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      final tail = backend.calls.where(
        (c) => c == 'clear' || c.startsWith('addMany'),
      );
      expect(tail, ['clear', 'addMany aaaaaaaaaaa,bbbbbbbbbbb next=false']);
    });

    testWidgets('a song tapped plays from there, with the rest behind it', (
      tester,
    ) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'addMany bbbbbbbbbbb next=false');
    });

    testWidgets('in a room the songs are added, never replacing the queue', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.likedSongs = [songA];
      backend.emit(StateEvent(sampleRoom()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();

      expect(find.text('Play'), findsNothing);
      await tester.tap(find.text('Add all'));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('clear')));
      expect(backend.calls.last, 'addMany aaaaaaaaaaa next=false');
    });

    testWidgets('an unliked song leaves the liked list', (tester) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TrackMenu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlike'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('like aaaaaaaaaaa false'));
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('the history says how long ago, and can be cleared', (
      tester,
    ) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Recently played'));
      await tester.pumpAndSettle();
      expect(find.text('Ben · 5 min ago'), findsOneWidget);

      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('clearHistory'));
      expect(find.text('Ben · 5 min ago'), findsNothing);
    });

    Future<void> openPlaylists(WidgetTester tester, FakeBackend backend) async {
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
    }

    testWidgets('a new playlist is named, made and opened', (tester) async {
      final (backend, _) = await pumpApp(tester);
      await openPlaylists(tester, backend);

      await tester.tap(find.byTooltip('New playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New playlist').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Road trip');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('createPlaylist Road trip '));
      expect(find.text('Road trip'), findsOneWidget);
      expect(find.text('This playlist is empty'), findsOneWidget);
    });

    testWidgets('a YouTube link becomes a playlist with its songs', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.lookupResult = const LinkResult(
        playlistTitle: 'Chill mix',
        tracks: [songA, songB],
      );
      await openPlaylists(tester, backend);

      await tester.tap(find.byTooltip('New playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from a link'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://www.youtube.com/playlist?list=PLabc',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        backend.calls,
        contains('createPlaylist Chill mix aaaaaaaaaaa,bbbbbbbbbbb'),
      );
      expect(find.text('Chill mix'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('a link that is not music says so and makes nothing', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      await openPlaylists(tester, backend);

      await tester.tap(find.byTooltip('New playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from a link'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https://example.com');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read that link'), findsOneWidget);
      expect(
        backend.calls.where((c) => c.startsWith('createPlaylist')),
        isEmpty,
      );
    });

    testWidgets('a playlist plays outside a room, and a song is swiped out', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.playlistNames[1] = 'Mix';
      backend.playlistSongs[1] = [songA, songB];
      await openPlaylists(tester, backend);

      await tester.tap(find.text('Mix'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      final started = backend.calls.where(
        (c) => c == 'clear' || c.startsWith('addMany'),
      );
      expect(started, ['clear', 'addMany aaaaaaaaaaa,bbbbbbbbbbb next=false']);

      await tester.drag(find.text('Alpha'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('removeFromPlaylist 1 aaaaaaaaaaa'));
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('deleting a playlist asks first and goes back to the library', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.playlistNames[1] = 'Mix';
      backend.playlistSongs[1] = [songA];
      await openPlaylists(tester, backend);

      await tester.tap(find.text('Mix'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This cannot be undone'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('deletePlaylist 1'));
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Mix'), findsNothing);
    });

    testWidgets('a song from search goes into a chosen playlist', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.playlistNames[1] = 'Mix';
      backend.playlistSongs[1] = [];
      backend.searchResults = [songA];
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TrackMenu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mix'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('addToPlaylist 1 aaaaaaaaaaa'));
      expect(find.text('Added to Mix'), findsOneWidget);

      // The same song again is recognised
      await tester.tap(find.byType(TrackMenu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mix'));
      await tester.pumpAndSettle();
      expect(find.text('Already in Mix'), findsOneWidget);
    });

    testWidgets('the picker can start a new playlist for the song', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(MiniPlayer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(
        find.descendant(
          of: find.byType(NowPlayingPage),
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Favourites');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('createPlaylist Favourites video0'));
      expect(find.text('Added to Favourites'), findsOneWidget);
    });

    testWidgets('the heart in the full player likes the song that is playing', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(MiniPlayer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.byTooltip('Like').first);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('like video0 true'));
      expect(find.byTooltip('Unlike'), findsWidgets);
    });
  });

  group('downloads and storage', () {
    const songA = Track(
      videoId: 'aaaaaaaaaaa',
      title: 'Alpha',
      artist: 'Ann',
      durMs: 100000,
    );
    const songB = Track(
      videoId: 'bbbbbbbbbbb',
      title: 'Beta',
      artist: 'Ben',
      durMs: 100000,
    );

    Future<FakeBackend> openSearchWith(
      WidgetTester tester, {
      bool metered = false,
    }) async {
      final (backend, _) = await pumpApp(tester);
      backend.metered = metered;
      backend.searchResults = [songA];
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      return backend;
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byType(TrackMenu).first);
      await tester.pumpAndSettle();
    }

    testWidgets('a song can be downloaded from its menu', (tester) async {
      final backend = await openSearchWith(tester);
      await openMenu(tester);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('download aaaaaaaaaaa metered=false'));
      expect(find.text('Downloading 1 song'), findsOneWidget);

      // While it waits the menu says so instead of offering it again
      await openMenu(tester);
      expect(find.text('Downloading…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    testWidgets('on mobile data the person is asked, and can say no', (
      tester,
    ) async {
      final backend = await openSearchWith(tester, metered: true);
      await openMenu(tester);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.text('Use mobile data?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.contains('metered=true')), isEmpty);
      expect(backend.downloadList, isEmpty);
    });

    testWidgets('on mobile data agreeing starts the download', (tester) async {
      final backend = await openSearchWith(tester, metered: true);
      await openMenu(tester);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download').last);
      await tester.pumpAndSettle();

      expect(backend.calls, contains('download aaaaaaaaaaa metered=true'));
      expect(backend.downloadList, hasLength(1));
    });

    testWidgets('a downloaded song is marked and can be removed', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.downloadList.add(
        const DownloadEntry(
          track: songA,
          state: DownloadState.done,
          bytes: 4096,
        ),
      );
      backend.searchResults = [songA];
      backend.emit(const LibraryEvent());
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
      await openMenu(tester);
      await tester.tap(find.text('Remove download'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('removeDownload aaaaaaaaaaa'));
      expect(find.byIcon(Icons.download_done_rounded), findsNothing);
    });

    Future<FakeBackend> openLibrary(WidgetTester tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.downloadList.addAll([
        const DownloadEntry(
          track: songA,
          state: DownloadState.done,
          bytes: 4 * 1024 * 1024,
        ),
        const DownloadEntry(track: songB, state: DownloadState.queued),
      ]);
      backend.likedSongs = [songA, songB];
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('the library lists what is downloaded and what waits', (
      tester,
    ) async {
      await openLibrary(tester);
      expect(find.text('Downloaded'), findsOneWidget);
      expect(
        find.text('1 song'),
        findsOneWidget,
        reason: 'only the finished one counts',
      );

      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();
      expect(find.text('Ann · 4.0 MB'), findsOneWidget);
      expect(find.text('Ben · Waiting to download'), findsOneWidget);
    });

    testWidgets('all downloads can be deleted after a question', (
      tester,
    ) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete all'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Remove every downloaded song'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('clearDownloads'));
      expect(find.text('Nothing downloaded'), findsOneWidget);
    });

    testWidgets('the liked songs can be downloaded in one go', (tester) async {
      final backend = await openLibrary(tester);
      await tester.tap(find.text('Liked songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download all'));
      await tester.pumpAndSettle();
      expect(
        backend.calls,
        contains('download aaaaaaaaaaa,bbbbbbbbbbb metered=false'),
      );
    });

    Future<FakeBackend> openSettings(
      WidgetTester tester, {
      String topic = 'storage',
    }) async {
      final (backend, _) = await pumpApp(tester);
      backend.storageInfo = const StorageInfo(
        playBytes: 50 * 1024 * 1024,
        playLimitMb: 256,
        downloadBytes: 12 * 1024 * 1024,
        downloadCount: 3,
      );
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await openTopic(tester, topic);
      return backend;
    }

    testWidgets('settings show what the kept songs take', (tester) async {
      await openSettings(tester);
      expect(find.text('3 songs · 12.0 MB'), findsOneWidget);
      expect(find.text('50.0 MB / 256 MB'), findsOneWidget);
    });

    testWidgets('the played songs can be cleared and their size chosen', (
      tester,
    ) async {
      final backend = await openSettings(tester);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('clearPlayCache'));

      await tester.tap(find.text('512 MB'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('cacheLimit 512'));
    });

    testWidgets('liked songs can be downloaded by themselves', (tester) async {
      final backend = await openSettings(tester);
      await tester.ensureVisible(find.text('Download liked songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download liked songs'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('autoDownload true'));
    });

    testWidgets('the library is saved to a file and added back from one', (
      tester,
    ) async {
      final backend = await openSettings(tester, topic: 'backup');
      await tester.tap(find.text('Save your library to a file'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('backupExport'));
      expect(find.text('Saved: 2 liked, 1 playlist'), findsOneWidget);

      backend.backupCounts = const BackupCounts(listens: 40);
      await tester.tap(find.text('Add from a backup file'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('backupImport'));
      expect(find.text('Added: 40 listens'), findsOneWidget);

      backend.backupCounts = const BackupCounts();
      await tester.tap(find.text('Add from a backup file'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing new in that file'), findsOneWidget);

      // Backing out of the file picker says nothing
      backend.backupCounts = null;
      await tester.tap(find.text('Save your library to a file'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved'), findsNothing);
    });
  });

  group('suggestions and search history', () {
    const songA = Track(
      videoId: 'aaaaaaaaaaa',
      title: 'Alpha',
      artist: 'Ann',
      durMs: 100000,
    );
    const songB = Track(
      videoId: 'bbbbbbbbbbb',
      title: 'Beta',
      artist: 'Ben',
      durMs: 100000,
    );

    Future<void> openSearch(WidgetTester tester, FakeBackend backend) async {
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'songs for you are there when search opens, and a touch plays one',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.forYouSongs = [songA, songB];
        backend.emit(const LibraryEvent());
        await openSearch(tester, backend);

        expect(find.text('For you'), findsOneWidget);
        expect(find.text('Alpha'), findsOneWidget);
        await tester.tap(find.text('Alpha'));
        await tester.pumpAndSettle();
        // Outside a room the song replaces the queue and songs like it follow
        expect(
          backend.calls,
          containsAllInOrder([
            'clear',
            'addMany aaaaaaaaaaa next=false',
            'radio aaaaaaaaaaa',
          ]),
        );
      },
    );

    testWidgets('pulling the list down asks for fresh suggestions', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.forYouSongs = [songA];
      backend.refreshedSongs = [songB];
      backend.emit(const LibraryEvent());
      await openSearch(tester, backend);

      await tester.fling(find.text('Alpha'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('refreshSuggestions'));
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('with nothing to suggest the page keeps its hint', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      await openSearch(tester, backend);
      expect(find.text('For you'), findsNothing);
      expect(find.text('Find something to play'), findsOneWidget);
    });

    testWidgets(
      'recent searches are listed, run again with a tap and cleared',
      (tester) async {
        final (backend, _) = await pumpApp(
          tester,
          prefs: {
            'recent_searches': ['lofi girl', 'jazz'],
          },
        );
        backend.searchResults = [songA];
        await openSearch(tester, backend);

        expect(find.text('Recent searches'), findsOneWidget);
        await tester.tap(find.text('jazz'));
        await tester.pumpAndSettle();
        expect(backend.calls, contains('search jazz'));
        expect(find.text('Alpha'), findsOneWidget);
      },
    );

    testWidgets('a recent search can be removed and all of them cleared', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(
        tester,
        prefs: {
          'recent_searches': ['lofi girl', 'jazz'],
        },
      );
      await openSearch(tester, backend);

      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      expect(find.text('lofi girl'), findsNothing);
      expect(find.text('jazz'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Recent searches'), findsNothing);
    });

    testWidgets(
      'typing offers completions, and one runs the search and is remembered',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.suggestions = ['lofi girl', 'lofi beats'];
        backend.searchResults = [songA];
        await openSearch(tester, backend);

        await tester.enterText(find.byType(TextField), 'lofi');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(backend.calls, contains('suggest lofi'));
        expect(find.text('lofi beats'), findsOneWidget);

        await tester.tap(find.text('lofi beats'));
        await tester.pumpAndSettle();
        expect(backend.calls, contains('search lofi beats'));
        expect(find.text('Alpha'), findsOneWidget);
        expect(
          find.text('lofi girl'),
          findsNothing,
          reason: 'the chips went away',
        );

        // Back to an empty field: the search is in the recent ones
        await tester.tap(find.byIcon(Icons.cancel_rounded));
        await tester.pumpAndSettle();
        expect(find.text('Recent searches'), findsOneWidget);
        expect(find.text('lofi beats'), findsOneWidget);
      },
    );

    testWidgets('a search that led to adding a song is remembered', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.searchResults = [songA];
      await openSearch(tester, backend);

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 2)); // the check mark times out
      await tester.tap(find.byIcon(Icons.cancel_rounded));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsOneWidget);
    });

    testWidgets('a pasted link gets no completions', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.suggestions = ['nope'];
      await openSearch(tester, backend);

      await tester.enterText(
        find.byType(TextField),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls.where((c) => c.startsWith('suggest')), isEmpty);
    });

    testWidgets('the autoplay switch in settings tells the native side', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await openTopic(tester, 'playback');

      await tester.tap(find.text('Autoplay').last);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('autoplay false'));
    });
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
