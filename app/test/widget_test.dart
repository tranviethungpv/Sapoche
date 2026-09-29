import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unison/app.dart';
import 'package:unison/data/app_settings.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/recent_rooms.dart';
import 'package:unison/data/room_controller.dart';
import 'package:unison/ui/now_playing_page.dart';
import 'package:unison/ui/scope.dart';
import 'package:unison/ui/widgets/shimmer.dart';
import 'package:unison/ui/widgets/mini_player.dart';

import 'fake_backend.dart';

Future<(FakeBackend, RoomController)> pumpApp(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
  Map<String, Object> prefs = const {},
}) async {
  // A tall phone-shaped window; the default 800x600 one is not what the app runs on. Test text is
  // drawn with the wide Ahem font, so it is 540 dp wide instead of the usual 360 to avoid false overflows.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'theme_mode': mode.name, ...prefs});
  final backend = FakeBackend();
  final recents = await RecentRooms.load();
  final room = RoomController(backend, recents: recents);
  final settings = await AppSettings.load();
  await tester.pumpWidget(
    UnisonApp(
      model: AppModel(room: room, settings: settings, recents: recents),
    ),
  );
  await room.start();
  return (backend, room);
}

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
          expect(
            find.text('Create a room'),
            findsNothing,
            reason: 'the sheet closes once the room is being made',
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
    await tester.pumpAndSettle();

    backend.emit(const InviteEvent('K2A5RF'));
    await tester.pumpAndSettle();
    expect(find.text('K2A5RF'), findsOneWidget);

    await tester.tap(find.text('Join').last);
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'join K2A5RF Anna');
  });

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

  testWidgets('settings have no room section outside a room', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('Leave room', skipOffstage: false), findsNothing);
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
    },
  );

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

    expect(find.text('K2A5RF · Expired'), findsOneWidget);
    await tester.tap(find.text('K2A5RF · Expired'), warnIfMissed: false);
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
      backend.emit(const NoticeEvent(kind: 'paused', by: 'Binh'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Binh paused the room'), findsOneWidget);

      await tester.tap(find.text('Keep playing'));
      await tester.pump();
      expect(backend.calls.last, 'keepPlaying');
    },
  );

  testWidgets(
    'the player switches between audio and video, and only asks for the picture while showing it',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(MiniPlayer));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Texture), findsNothing);
      expect(backend.calls, isNot(contains('videoSurface')));

      await tester.tap(find.text('Video'));
      await tester.pump();
      expect(backend.calls.last, 'video true');

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
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'lofi');
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.calls.last, 'search lofi');

    await tester.tap(find.text('Songs'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.calls.last, 'search lofi songs');
  });

  testWidgets(
    'searching playlists lists them, and one can be opened and left again',
    (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
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

      await tester.tap(find.text('Song 0'));
      await tester.pump();
      expect(backend.calls.last, 'jump q0');

      await tester.drag(find.text('Song 1'), const Offset(-800, 0));
      await tester.pump();
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
    // The mini player shows the title too; the queue row comes first
    await tester.drag(find.text('Song 0').first, const Offset(-800, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.calls.last, 'remove q0');
  });

  testWidgets('when the queue has finished, the room offers to play it again', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom(songs: 3, index: 2, phase: 'idle')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('The queue has finished'), findsOneWidget);

    await tester.tap(find.text('Play again'));
    await tester.pump();
    expect(backend.calls.last, 'play');

    backend.emit(StateEvent(sampleRoom(songs: 3, index: 2)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('The queue has finished'), findsNothing);
  });

  testWidgets('Back closes the open player instead of leaving the app', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
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
