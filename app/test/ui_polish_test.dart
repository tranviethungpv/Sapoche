import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/home_model.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/cover_glow.dart';
import 'package:sapoche/ui/widgets/avatars.dart';
import 'package:sapoche/ui/widgets/mix_cover.dart';
import 'package:sapoche/ui/widgets/motion.dart';
import 'package:sapoche/ui/widgets/qr_code_view.dart';

import 'fake_backend.dart';
import 'home_page_test.dart' show musicSong, openHome, song;
import 'pump_app.dart';

/// The room page with its people, the invitation and settings sheets, the way in with no server, and the home page
/// with little on it (`docs/plans/2026-11-11-ui-polish.md`, G4 to G8 and G10).
void main() {
  const three = [
    Member(id: 'me', name: 'Anna', ready: true, owner: true),
    Member(id: 'b', name: 'Binh', ready: true),
    Member(id: 'c', name: 'Chi', ready: true, away: true),
  ];

  group('the room page', () {
    testWidgets(
      'shows everyone as a face with a name, and the song that is on',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(StateEvent(sampleRoom(members: three)));
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
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        for (final id in ['me', 'b', 'c']) {
          expect(find.byKey(ValueKey('person-$id')), findsOneWidget);
        }
        expect(find.text('Binh'), findsOneWidget);
        // The card of the song that is on: its person in words, how in step this device is, and a button
        final card = find.byKey(const ValueKey('room-now-card'));
        expect(card, findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.textContaining('Added by')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.textContaining('In sync')),
          findsOneWidget,
        );
        // The code is on the invitation, not on the page; and there is no page of nothing
        expect(find.text('ABC234'), findsNothing);
        expect(find.byKey(const ValueKey('room-alone')), findsNothing);
      },
    );

    testWidgets(
      'somebody who comes in later pops in, and those already there do not',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(StateEvent(sampleRoom(members: three)));
        await tester.pump(const Duration(milliseconds: 500));
        backend.emit(
          StateEvent(
            sampleRoom(
              members: [
                ...three,
                const Member(id: 'd', name: 'Dung', ready: true),
              ],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.widget<Pop>(find.byKey(const ValueKey('pop-d'))).animate,
          isTrue,
        );
        expect(
          tester.widget<Pop>(find.byKey(const ValueKey('pop-b'))).animate,
          isFalse,
        );
      },
    );

    testWidgets('with a crowd the faces get smaller and nothing overflows', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            members: [
              for (var i = 0; i < 9; i++)
                Member(
                  id: 'm$i',
                  name: 'Person $i',
                  ready: true,
                  owner: i == 0,
                ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('person-m0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'alone in an empty room the page invites somebody, with the code to scan',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(
          StateEvent(
            sampleRoom(
              songs: 0,
              phase: 'idle',
              members: const [Member(id: 'me', name: 'Anna', ready: true)],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('room-alone')), findsOneWidget);
        expect(find.text(S.listeningAlone), findsOneWidget);
        expect(find.byType(QrCodeView), findsOneWidget);
        // Songs can be added from where the invitation is
        expect(find.text(S.addSongs), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('with company an empty queue is only a note and a button', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(sampleRoom(songs: 0, phase: 'idle', members: three)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-alone')), findsNothing);
      expect(find.text(S.emptyQueueTitle), findsOneWidget);
      expect(find.text(S.addSongs), findsOneWidget);
    });

    testWidgets(
      'the fourth tab is called Room in a room and Listen out of one',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        expect(find.text(S.tabListen), findsWidgets);
        backend.emit(StateEvent(sampleRoom(members: three)));
        await tester.pumpAndSettle();
        expect(find.text(S.tabListen), findsNothing);
        expect(find.text(S.tabRoom), findsWidgets);
        backend.emit(const StateEvent(RoomSnapshot()));
        await tester.pumpAndSettle();
        expect(find.text(S.tabListen), findsWidgets);
      },
    );
  });

  group('the room sheet', () {
    Future<FakeBackend> inRoom(WidgetTester tester, {bool owner = true}) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        StateEvent(
          sampleRoom(
            ownerId: owner ? 'me' : 'b',
            roomWaitWeak: false,
            members: three,
          ),
        ),
      );
      // The server keeps a chat, which is what the encryption row is about
      backend.emit(
        const ChatEvent(room: 'ABC234', messages: [], replace: true),
      );
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets(
      'opens on the invitation, with the code, and no switch in sight',
      (tester) async {
        await inRoom(tester);
        await tester.tap(find.byTooltip(S.invite));
        await tester.pumpAndSettle();
        expect(find.byType(QrCodeView), findsOneWidget);
        expect(find.text('ABC234'), findsOneWidget);
        expect(find.text(S.copyLink), findsOneWidget);
        expect(find.byType(Switch), findsNothing);
        expect(find.text(S.encryptionTitle), findsNothing);
      },
    );

    testWidgets(
      'the settings are rows with a line each, and the encryption one is short',
      (tester) async {
        final backend = await inRoom(tester);
        await tester.tap(find.byTooltip(S.roomSettings));
        await tester.pumpAndSettle();
        // Listen together, guests add only, wait for slow connections, and the encryption, all of the one make
        expect(find.byType(Switch), findsNWidgets(4));
        expect(find.text(S.listenTogether), findsOneWidget);
        expect(find.text(S.guestsAddOnly), findsOneWidget);
        expect(find.text(S.waitWeak), findsOneWidget);
        // One sentence about encryption, the whole story behind "Learn more"
        expect(find.text(S.encryptionShort), findsOneWidget);
        expect(find.text(S.encryptionOffHelp), findsNothing);
        await tester.ensureVisible(find.text(S.learnMore));
        await tester.tap(find.text(S.learnMore));
        await tester.pumpAndSettle();
        expect(find.text(S.encryptionOffHelp), findsOneWidget);
        await tester.tap(find.text(S.close));
        await tester.pumpAndSettle();

        // Listening together is switched from here
        await tester.tap(find.byType(Switch).first);
        await tester.pump();
        expect(backend.calls.last, 'solo true');
      },
    );

    testWidgets('from the invitation a button leads to the settings', (
      tester,
    ) async {
      await inRoom(tester);
      await tester.tap(find.byTooltip(S.invite));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.roomSettings));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsWidgets);
      expect(find.byType(QrCodeView), findsNothing);
    });

    testWidgets(
      'a guest has the people and leaving, and not the owner switches',
      (tester) async {
        await inRoom(tester, owner: false);
        await tester.tap(find.byTooltip(S.roomSettings));
        await tester.pumpAndSettle();
        expect(find.text(S.guestsAddOnly), findsNothing);
        expect(find.text(S.waitWeak), findsNothing);
        expect(find.text(S.listenTogether), findsOneWidget);
        expect(find.text(S.leaveRoom), findsOneWidget);
      },
    );
  });

  group('with no server', () {
    testWidgets(
      'the room sheet says what to do first, and makes no error of it',
      (tester) async {
        final (backend, _) = await pumpApp(
          tester,
          profile: const Profile(
            name: 'Anna',
            configured: false,
            hasKey: false,
          ),
        );
        backend.emit(const StateEvent(RoomSnapshot()));
        await tester.pumpAndSettle();
        await tester.tap(find.text(S.tabRoom));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('room-needs-setup')), findsOneWidget);
        expect(find.text(S.setupNeededTitle), findsOneWidget);
        expect(find.byKey(const ValueKey('room-setup-paste')), findsOneWidget);
        expect(find.byKey(const ValueKey('room-setup-manual')), findsOneWidget);
        // Neither the name nor the buttons that would only be refused
        expect(find.byType(TextField), findsNothing);
        expect(find.text(S.createRoom), findsNothing);
        expect(find.text(S.serverNotSet), findsNothing);
      },
    );

    testWidgets('what is pasted that is not a setup link is said so', (
      tester,
    ) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': 'not a link'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (backend, _) = await pumpApp(
        tester,
        profile: const Profile(name: 'Anna', configured: true, hasKey: false),
      );
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.tabRoom));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-setup-paste')));
      await tester.pumpAndSettle();
      expect(find.text(S.setupBad), findsOneWidget);
    });

    testWidgets(
      'with a server and its key the sheet asks for a name as before',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(const StateEvent(RoomSnapshot()));
        await tester.pumpAndSettle();
        await tester.tap(find.text(S.tabRoom));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('room-needs-setup')), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
      },
    );
  });

  group('the room chip on the home page', () {
    testWidgets('shows the faces and how many listen while in a room', (
      tester,
    ) async {
      final backend = await openHome(tester, inRoom: true);
      expect(find.byType(AvatarStack), findsOneWidget);
      expect(find.text('ABC234'), findsNothing);
      backend.emit(
        StateEvent(sampleRoom(songs: 0, phase: 'idle', members: three)),
      );
      await tester.pumpAndSettle();
      // Chi is away: not counted
      expect(find.text('2'), findsOneWidget);
    });
  });

  group('the home page with little on it', () {
    /// One taste: mornings, Adele, Beck and Cher, four songs each.
    void oneTaste(FakeBackend b) {
      final now = DateTime.now();
      final listens = <HistoryEntry>[];
      for (var d = 1; d <= 8; d++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: 2 * d));
        for (final (i, a) in ['Adele', 'Beck', 'Cher'].indexed) {
          listens.add(
            HistoryEntry(
              track: song('${a.toLowerCase()}${d % 4}aaaa', 'Song ${d % 4}', a),
              at: day.add(Duration(hours: 8, minutes: 4 * i)),
            ),
          );
        }
      }
      b.listenResults = listens;
      final byId = <String, HistoryEntry>{};
      for (final e in listens) {
        final kept = byId[e.track.videoId];
        byId[e.track.videoId] = HistoryEntry(
          track: e.track,
          at: kept == null || e.at.isAfter(kept.at) ? e.at : kept.at,
          plays: (kept?.plays ?? 0) + 1,
        );
      }
      b.recentSongs = byId.values.toList()
        ..sort((a, b) => b.at.compareTo(a.at));
      b.homeResult = const MusicHome(
        chips: [MoodChip(label: 'Relax', params: 'p-relax')],
      );
    }

    testWidgets('a single mix is one slim row, with a small round Play', (
      tester,
    ) async {
      final backend = await openHome(tester, prepare: oneTaste);
      final mix = find.byKey(const ValueKey('mix-1'));
      expect(mix, findsOneWidget);
      expect(find.byKey(const ValueKey('mix-2')), findsNothing);
      // Across the page, not a card of a shelf with the rest of the row empty, and not a tall one either
      final size = tester.getSize(mix);
      expect(size.width, greaterThan(tester.view.physicalSize.width / 2 / 2));
      expect(size.height, lessThan(110));
      expect(
        find.descendant(of: mix, matching: find.byType(MixCover)),
        findsOneWidget,
      );
      expect(tester.getSize(find.byKey(const ValueKey('mix-play'))).height, 40);
      await tester.tap(find.byKey(const ValueKey('mix-play')));
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('addMany')), isNotEmpty);
    });

    testWidgets(
      'a rule parts the chips that play from the moods that open a list',
      (tester) async {
        await openHome(tester, prepare: oneTaste);
        final own = tester.getRect(find.byKey(const ValueKey('chip-mix-1')));
        final mood = tester.getRect(find.byKey(const ValueKey('mood-p-relax')));
        // More than the 8 that parts chips of one kind: there is a rule between them
        expect(mood.left - own.right, greaterThan(16));
      },
    );

    testWidgets(
      'somebody new with a room behind them is offered it before the charts',
      (tester) async {
        final recent = {
          'recent_rooms':
              '[{"code":"XYZ234","name":"Home","at":${DateTime.now().millisecondsSinceEpoch}}]',
        };
        await openHome(
          tester,
          prefs: recent,
          prepare: (b) => b.chartsResult = [
            MusicShelf(
              title: 'Top songs',
              tracks: [musicSong('hit1aaaaaaa', 'Hit One', 'Star')],
            ),
          ],
        );
        expect(
          find.byKey(const ValueKey('listen-with-friends')),
          findsOneWidget,
        );
        expect(find.text(S.listenWithFriends), findsOneWidget);
        // The charts are said to be YouTube Music's, and come after the card
        expect(find.text(S.fromYouTubeMusic), findsOneWidget);
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('listen-with-friends')))
              .dy,
          lessThan(tester.getTopLeft(find.text(S.fromYouTubeMusic)).dy),
        );
      },
    );

    testWidgets('and not without a room to go back to', (tester) async {
      await openHome(tester);
      expect(find.byKey(const ValueKey('listen-with-friends')), findsNothing);
    });

    testWidgets('nor once the person has music of their own', (tester) async {
      await openHome(
        tester,
        prepare: oneTaste,
        prefs: {
          'recent_rooms':
              '[{"code":"XYZ234","name":"Home","at":${DateTime.now().millisecondsSinceEpoch}}]',
        },
      );
      expect(find.byKey(const ValueKey('listen-with-friends')), findsNothing);
      expect(find.text(S.fromYouTubeMusic), findsNothing);
    });
  });

  group('the mix cover', () {
    testWidgets(
      'has its words and a colour of its own with no picture to draw',
      (tester) async {
        final mix1 = DailyMix(
          number: 1,
          artists: const ['Adele', 'Beck', 'Cher'],
          tracks: const [],
        );
        final mix2 = DailyMix(
          number: 2,
          artists: const ['Drake'],
          tracks: const [],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Row(
              children: [
                MixCover(mix: mix1, size: 140),
                MixCover(mix: mix2, size: 140),
              ],
            ),
          ),
        );
        expect(find.text('Mix 1'), findsOneWidget);
        expect(find.text('Mix 2'), findsOneWidget);
        expect(find.text('Adele · Beck · Cher'), findsOneWidget);
        expect(
          CoverGlow.toneFor(1),
          isNot(CoverGlow.toneFor(2)),
          reason: 'each mix has its own colour',
        );
      },
    );

    test('whatever the picture, the colour it gives lets white words read at 4.5:1', () {
      double luminance(Color c) {
        double f(double v) => v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
      }

      for (final c in const [
        Color(0xFFFFFFFF),
        Color(0xFFFFD600),
        Color(0xFF00C8E6),
        Color(0xFFE61E3C),
        Color(0xFF808080),
        Color(0xFF000000),
      ]) {
        final tone = CoverGlow.deepen(c);
        expect(
          1.05 / (luminance(tone) + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: '$c',
        );
      }
      for (var n = 1; n <= 12; n++) {
        expect(
          1.05 / (luminance(CoverGlow.toneFor(n)) + 0.05),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  });
}
