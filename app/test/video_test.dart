import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/ui/player/video_controls.dart';
import 'package:sapoche/ui/widgets/like_button.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/playback_bar.dart';
import 'package:sapoche/ui/widgets/video_view.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// Calls to the system: the screen's orientations and whether its bars show.
final systemCalls = <MethodCall>[];

/// The orientations last asked for, as the system channel carries them; empty is "any".
List<String>? lastOrientations() {
  for (final call in systemCalls.reversed) {
    if (call.method == 'SystemChrome.setPreferredOrientations') {
      return (call.arguments as List).cast<String>();
    }
  }
  return null;
}

String? lastUiMode() {
  for (final call in systemCalls.reversed) {
    if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
      return call.arguments as String;
    }
  }
  return null;
}

void recordSystem(WidgetTester tester) {
  systemCalls.clear();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      systemCalls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

Future<void> settle(WidgetTester tester, [int ms = 700]) async {
  await tester.pump();
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> resize(WidgetTester tester, double width, double height) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  await settle(tester, 500);
}

PlayerPosition picture(
  int width,
  int height, {
  bool playing = true,
  bool buffering = false,
  int positionMs = 4000,
  int durationMs = 200000,
}) => PlayerPosition(
  playing: playing,
  buffering: buffering,
  positionMs: positionMs,
  durationMs: durationMs,
  videoWidth: width,
  videoHeight: height,
);

/// The room controller of the app [openVideo] opened.
late RoomController lastRoom;

/// Opens the full player on a song shown as a video of [width] x [height] pixels, on a [screen] sized window.
Future<FakeBackend> openVideo(
  WidgetTester tester, {
  RoomSnapshot? snapshot,
  int width = 1280,
  int height = 720,
  Size screen = const Size(540, 1200),
  int positionMs = 4000,
  bool pip = true,
}) async {
  recordSystem(tester);
  final (backend, room) = await pumpApp(tester, pipSupported: pip);
  lastRoom = room;
  tester.view.physicalSize = screen * 2;
  backend.emit(StateEvent(snapshot ?? sampleRoom(video: true)));
  // The room plays; the phone's last sample stands still, so that where a tap moves the song is exact
  backend.emit(
    PositionEvent(
      picture(width, height, positionMs: positionMs, playing: false),
    ),
  );
  await settle(tester, 1000);
  await tester.tap(find.byType(MiniPlayer));
  await settle(tester);
  return backend;
}

/// The frame of the picture in the player.
Finder get frame => find.descendant(
  of: find.byKey(const ValueKey('video')),
  matching: find.byType(AspectRatio),
);

VideoControlsState controlsOf(WidgetTester tester, {bool full = false}) =>
    tester.state<VideoControlsState>(
      find
          .byWidgetPredicate((w) => w is VideoControls && w.fullScreen == full)
          .first,
    );

/// A tap at [fraction] of the picture's width, in its middle.
Future<void> tapPicture(
  WidgetTester tester,
  double fraction, {
  bool full = false,
}) async {
  final rect = tester.getRect(full ? find.byType(VideoFullScreen) : frame);
  // A third of the way down: clear of the buttons, which sit in the middle and the corners
  await tester.tapAt(
    Offset(rect.left + rect.width * fraction, rect.top + rect.height * 0.3),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

List<int> seeks(FakeBackend backend) => [
  for (final c in backend.calls)
    if (c.startsWith('seek ')) int.parse(c.substring(5)),
];

/// A widget test that lets the timers of a seek or of the controls run out before it ends.
void videoTest(String description, Future<void> Function(WidgetTester) body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

void main() {
  tearDown(() => VideoFullScreen.open.value = false);

  group('the picture keeps its shape and its place', () {
    const pictures = {
      'wide 16:9': (1280, 720),
      'upright 9:16': (720, 1280),
      'square': (720, 720),
      'cinema 21:9': (2560, 1080),
      'old 4:3': (640, 480),
      'very tall 9:21': (1080, 2520),
      'a sliver 1:3': (400, 1200),
      'tiny 2x2': (2, 2),
    };
    // Test text is the wide Ahem font, so the phones are drawn wider than they are; the sizes still cover short and
    // tall screens, and a tablet held upright
    const screens = [
      Size(540, 960),
      Size(540, 1200),
      Size(600, 1000),
      Size(800, 1280),
    ];
    for (final room in [true, false]) {
      for (final MapEntry(key: name, value: (w, h)) in pictures.entries) {
        for (final screen in screens) {
          videoTest(
            '$name on ${screen.width.toInt()}x${screen.height.toInt()}${room ? ' in a room' : ''}',
            (tester) async {
              await openVideo(
                tester,
                snapshot: sampleRoom(video: true, local: !room),
                width: w,
                height: h,
                screen: screen,
              );
              expect(tester.takeException(), isNull);
              final rect = tester.getRect(frame);
              final place = tester.getRect(
                find.byKey(const ValueKey('video-place')),
              );
              // On the screen, inside its place, and above the title, the seek bar and the buttons
              expect(rect.left, greaterThanOrEqualTo(place.left - 0.5));
              expect(rect.right, lessThanOrEqualTo(place.right + 0.5));
              expect(rect.top, greaterThanOrEqualTo(place.top + 12 - 0.5));
              expect(rect.bottom, lessThanOrEqualTo(place.bottom - 16 + 0.5));
              final like = tester.getRect(
                find
                    .descendant(
                      of: find.byType(Scaffold).last,
                      matching: find.byType(LikeButton),
                    )
                    .first,
              );
              final bar = tester.getRect(find.byType(PlaybackBar));
              expect(rect.overlaps(like), isFalse, reason: 'over the title');
              expect(rect.overlaps(bar), isFalse, reason: 'over the bar');
              expect(rect.bottom, lessThan(like.top), reason: 'above');
              // Its own shape, to the pixel
              expect(rect.width / rect.height, closeTo(w / h, 0.01));
              // As large as the place allows: it fills the place's width or its height
              final width = place.width;
              final height = place.height - 28;
              final full =
                  (rect.width - width).abs() < 1 ||
                  (rect.height - height).abs() < 1;
              expect(full, isTrue, reason: '$rect in $place');
              // Never smaller than something one can watch
              expect(rect.shortestSide, greaterThan(80));
            },
          );
        }
      }
    }

    videoTest('a picture that changes shape with the next song follows it', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      expect(
        tester.getRect(frame).width / tester.getRect(frame).height,
        closeTo(16 / 9, 0.01),
      );
      backend.emit(PositionEvent(picture(720, 1280)));
      await settle(tester, 300);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(frame).width / tester.getRect(frame).height,
        closeTo(9 / 16, 0.01),
      );
    });

    videoTest('until the first frame, the place has the shape of a video', (
      tester,
    ) async {
      await openVideo(tester, width: 0, height: 0);
      expect(
        tester.getRect(frame).width / tester.getRect(frame).height,
        closeTo(16 / 9, 0.01),
      );
      expect(find.byType(Texture), findsNothing);
    });

    videoTest(
      'the player on its side on a tablet keeps the picture beside the controls',
      (tester) async {
        await openVideo(
          tester,
          width: 720,
          height: 1280,
          screen: const Size(800, 1280),
        );
        await resize(tester, 1280, 800);
        expect(tester.takeException(), isNull);
        expect(find.byType(VideoFullScreen), findsNothing);
        final video = tester.getRect(
          find.descendant(
            of: find.byType(VideoView),
            matching: find.byType(AspectRatio),
          ),
        );
        final bar = tester.getRect(find.byType(PlaybackBar));
        expect(video.right, lessThan(bar.left));
        expect(video.width / video.height, closeTo(9 / 16, 0.01));
        expect(video.bottom, lessThanOrEqualTo(800.5));
      },
    );
  });

  group('the controls over the picture', () {
    videoTest('a touch shows them, and they go by themselves while it plays', (
      tester,
    ) async {
      await openVideo(tester);
      expect(controlsOf(tester).shown, isFalse);
      expect(find.byTooltip(S.fullScreen), findsOneWidget);
      // Hidden controls cannot be pressed: a touch where one is only shows them
      await tester.tap(find.byTooltip(S.fullScreen), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(VideoFullScreen), findsNothing);
      expect(controlsOf(tester).shown, isTrue);
      await tester.pump(const Duration(milliseconds: 3000));
      expect(controlsOf(tester).shown, isFalse);

      await tapPicture(tester, 0.5);
      expect(controlsOf(tester).shown, isTrue);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(controlsOf(tester).shown, isTrue, reason: 'not yet');
      await tester.pump(const Duration(milliseconds: 200));
      expect(controlsOf(tester).shown, isFalse);
    });

    videoTest('another touch hides them at once', (tester) async {
      await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tester.pump(const Duration(milliseconds: 400));
      await tapPicture(tester, 0.5);
      expect(controlsOf(tester).shown, isFalse);
    });

    videoTest('paused, they stay; playing again, they go after a while', (
      tester,
    ) async {
      final backend = await openVideo(
        tester,
        snapshot: sampleRoom(video: true, phase: 'paused'),
      );
      expect(controlsOf(tester).shown, isTrue, reason: 'paused shows them');
      await tester.pump(const Duration(seconds: 10));
      expect(controlsOf(tester).shown, isTrue);
      backend.emit(StateEvent(sampleRoom(video: true)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3100));
      expect(controlsOf(tester).shown, isFalse);
    });

    videoTest('pressing play pauses the room and the controls stay for it', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.pause).first);
      await tester.pump();
      expect(backend.calls, contains('pause'));
      backend.emit(StateEvent(sampleRoom(video: true, phase: 'paused')));
      await tester.pump(const Duration(seconds: 6));
      expect(controlsOf(tester).shown, isTrue);
    });

    videoTest(
      'a double tap on the right goes forward ten seconds and leaves the controls as they were',
      (tester) async {
        final backend = await openVideo(tester);
        await tapPicture(tester, 0.85);
        await tapPicture(tester, 0.85);
        expect(seeks(backend), [14000]);
        expect(controlsOf(tester).shown, isFalse);
        expect(find.byKey(const ValueKey('skip-note-1')), findsOneWidget);
        expect(find.text(S.seconds(10)), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 900));
        expect(find.byKey(const ValueKey('skip-note-1')), findsNothing);
      },
    );

    videoTest('more taps right after go further, and the note counts them', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      for (var i = 0; i < 4; i++) {
        await tapPicture(tester, 0.9);
      }
      // The first tap only shows the controls; each one after it moves ten seconds from where the last one went
      expect(seeks(backend), [14000, 24000, 34000]);
      expect(find.text(S.seconds(30)), findsOneWidget);
      expect(controlsOf(tester).shown, isFalse);
    });

    videoTest('a double tap on the left goes back, never before the start', (
      tester,
    ) async {
      final backend = await openVideo(tester, positionMs: 25000);
      await tapPicture(tester, 0.1);
      await tapPicture(tester, 0.1);
      await tapPicture(tester, 0.1);
      await tapPicture(tester, 0.1);
      expect(seeks(backend), [15000, 5000, 0]);
      expect(find.byKey(const ValueKey('skip-note--1')), findsOneWidget);
    });

    videoTest('forward never goes past the end', (tester) async {
      final backend = await openVideo(tester, positionMs: 195000);
      await tapPicture(tester, 0.9);
      await tapPicture(tester, 0.9);
      await tapPicture(tester, 0.9);
      expect(seeks(backend), [200000, 200000]);
    });

    videoTest('a double tap in the middle moves nothing', (tester) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tapPicture(tester, 0.5);
      expect(seeks(backend), isEmpty);
      expect(controlsOf(tester).shown, isFalse, reason: 'shown then hidden');
    });

    videoTest('taps on both sides, slowly, do not count as a double tap', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.9);
      await tester.pump(const Duration(milliseconds: 400));
      await tapPicture(tester, 0.9);
      expect(seeks(backend), isEmpty);
      await tapPicture(tester, 0.1);
      await tester.pump(const Duration(milliseconds: 400));
      await tapPicture(tester, 0.9);
      expect(seeks(backend), isEmpty);
    });

    videoTest('once the note is gone, a tap on that side is a tap again', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.9);
      await tapPicture(tester, 0.9);
      await tester.pump(const Duration(milliseconds: 900));
      await tapPicture(tester, 0.9);
      expect(seeks(backend), hasLength(1));
      expect(controlsOf(tester).shown, isTrue);
    });

    videoTest(
      'a double tap on the other side goes back from where the last one went',
      (tester) async {
        final backend = await openVideo(tester, positionMs: 60000);
        await tapPicture(tester, 0.9);
        await tapPicture(tester, 0.9);
        await tapPicture(tester, 0.1);
        await tapPicture(tester, 0.1);
        expect(seeks(backend), [70000, 60000]);
      },
    );

    videoTest(
      'the buttons beside play move ten seconds and keep the controls a while longer',
      (tester) async {
        final backend = await openVideo(tester);
        await tapPicture(tester, 0.5);
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.tap(find.byTooltip(S.forward10));
        // The player says where it went
        backend.emit(
          PositionEvent(picture(1280, 720, positionMs: 14000, playing: false)),
        );
        await tester.pump(const Duration(milliseconds: 2500));
        expect(
          controlsOf(tester).shown,
          isTrue,
          reason: 'the timer started again',
        );
        await tester.tap(find.byTooltip(S.back10));
        expect(seeks(backend), [14000, 4000]);
        await tester.pump(const Duration(milliseconds: 3100));
        expect(controlsOf(tester).shown, isFalse);
      },
    );

    videoTest('while the room is starting, a spinner stands for play', (
      tester,
    ) async {
      await openVideo(
        tester,
        snapshot: sampleRoom(video: true, phase: 'preparing'),
      );
      await tapPicture(tester, 0.5);
      expect(
        find.descendant(
          of: find.byType(VideoControls),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip(S.pause), findsNothing);
    });

    videoTest('the small window button is there only where the phone has one', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.pictureInPicture));
      await tester.pump();
      expect(backend.calls, contains('pipEnter'));
    });

    videoTest('no small window button on a phone without one', (tester) async {
      await openVideo(tester, pip: false);
      await tapPicture(tester, 0.5);
      expect(find.byTooltip(S.pictureInPicture), findsNothing);
    });
  });

  group('the video settings', () {
    Future<void> openSettings(WidgetTester tester) async {
      if (!controlsOf(tester).shown) await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.videoSettings));
      await settle(tester, 500);
    }

    videoTest('choose the quality, with the one in use marked', (tester) async {
      final backend = await openVideo(tester);
      await openSettings(tester);
      expect(tester.takeException(), isNull);
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('quality-720')),
      );
      expect(chip.selected, isTrue);
      await tester.tap(find.byKey(const ValueKey('quality-1080')));
      await tester.pump();
      expect(backend.calls, contains('videoQuality 1080'));
    });

    videoTest('in a room the speed cannot be changed, and it says why', (
      tester,
    ) async {
      await openVideo(tester);
      await openSettings(tester);
      expect(find.text(S.speedInRoom), findsOneWidget);
      expect(find.byKey(const ValueKey('speed-1.5')), findsNothing);
    });

    videoTest('outside a room the speed is chosen, and the one in use marked', (
      tester,
    ) async {
      final backend = await openVideo(
        tester,
        snapshot: sampleRoom(video: true, local: true),
      );
      await openSettings(tester);
      expect(find.text(S.speedInRoom), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('speed-1.0')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('speed-1.5')));
      await tester.pump();
      expect(backend.calls, contains('speed 1.5'));
      backend.emit(
        StateEvent(
          RoomSnapshot.fromJson({
            'phase': 'paused',
            'video': true,
            'playbackSpeed': 1.5,
            'queue': [
              {
                'id': 'q0',
                'videoId': 'video0',
                'title': 'Song 0',
                'artist': 'Artist 0',
                'durMs': 200000,
                'addedBy': 'me',
              },
            ],
          }),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('speed-1.5')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('speed-1.0')))
            .selected,
        isFalse,
      );
      // Every speed fits on the sheet, on a narrow phone too
      for (final s in playbackSpeeds) {
        expect(find.byKey(ValueKey('speed-$s')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('the whole screen', () {
    Future<void> openFull(WidgetTester tester) async {
      await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.fullScreen));
      await settle(tester, 500);
    }

    videoTest(
      'a wide picture turns the phone on its side, with the bars away',
      (tester) async {
        await openVideo(tester);
        await openFull(tester);
        expect(find.byType(VideoFullScreen), findsOneWidget);
        expect(VideoFullScreen.open.value, isTrue);
        expect(lastUiMode(), 'SystemUiMode.immersiveSticky');
        expect(lastOrientations(), [
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]);
        // It opens with its controls, then they go as they do in the player
        expect(controlsOf(tester, full: true).shown, isTrue);
        expect(find.text('Song 0'), findsWidgets);
        await tester.pump(const Duration(milliseconds: 3100));
        expect(controlsOf(tester, full: true).shown, isFalse);
      },
    );

    videoTest('an upright picture keeps the phone upright', (tester) async {
      await openVideo(tester, width: 720, height: 1280);
      await openFull(tester);
      expect(lastOrientations(), ['DeviceOrientation.portraitUp']);
    });

    videoTest('a square picture counts as wide', (tester) async {
      await openVideo(tester, width: 720, height: 720);
      await openFull(tester);
      expect(lastOrientations(), [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
    });

    videoTest('a tablet is not turned', (tester) async {
      await openVideo(tester, screen: const Size(800, 1280));
      await openFull(tester);
      expect(find.byType(VideoFullScreen), findsOneWidget);
      expect(
        lastOrientations(),
        isNot(contains('DeviceOrientation.landscapeLeft')),
      );
    });

    for (final (how, leave) in <(String, Future<void> Function(WidgetTester))>[
      ('the arrow', (t) => t.tap(find.byTooltip(S.exitFullScreen).first)),
      (
        'the button by the bar',
        (t) => t.tap(find.byTooltip(S.exitFullScreen).last),
      ),
      ('Back', (t) => t.binding.handlePopRoute()),
    ]) {
      videoTest('$how leaves it, and the screen turns freely again', (
        tester,
      ) async {
        final backend = await openVideo(tester);
        await openFull(tester);
        await leave(tester);
        await settle(tester, 500);
        expect(find.byType(VideoFullScreen), findsNothing);
        expect(VideoFullScreen.open.value, isFalse);
        expect(lastUiMode(), 'SystemUiMode.edgeToEdge');
        expect(lastOrientations(), isEmpty);
        // Back in the player, which still shows the picture
        expect(find.byType(PlaybackBar), findsOneWidget);
        expect(
          backend.calls.lastWhere((c) => c.startsWith('videoVisible')),
          'videoVisible true',
        );
      });
    }

    videoTest(
      'pulling the picture down far enough leaves it; a little does not',
      (tester) async {
        await openVideo(tester);
        await openFull(tester);
        await tester.dragFrom(const Offset(270, 500), const Offset(0, 60));
        await settle(tester, 400);
        expect(find.byType(VideoFullScreen), findsOneWidget);
        await tester.dragFrom(const Offset(270, 400), const Offset(0, 300));
        await settle(tester, 500);
        expect(find.byType(VideoFullScreen), findsNothing);
      },
    );

    videoTest(
      'two fingers spread fill the screen, pinched fit it again, and the button does the same',
      (tester) async {
        await openVideo(tester);
        await openFull(tester);
        BoxFit fit() => tester
            .widget<FittedBox>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('full-screen-video')),
                    matching: find.byType(FittedBox),
                  )
                  .first,
            )
            .fit;
        expect(fit(), BoxFit.contain);

        Future<void> pinch(double from, double to) async {
          final a = await tester.startGesture(Offset(270 - from, 600));
          final b = await tester.startGesture(Offset(270 + from, 600));
          for (var i = 1; i <= 5; i++) {
            final d = from + (to - from) * i / 5;
            await a.moveTo(Offset(270 - d, 600));
            await b.moveTo(Offset(270 + d, 600));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await a.up();
          await b.up();
          await settle(tester, 200);
        }

        await pinch(60, 180);
        expect(fit(), BoxFit.cover);
        expect(
          find.byType(VideoFullScreen),
          findsOneWidget,
          reason: 'not left',
        );
        await pinch(180, 60);
        expect(fit(), BoxFit.contain);

        await tapPicture(tester, 0.5, full: true);
        if (!controlsOf(tester, full: true).shown) {
          await tapPicture(tester, 0.5, full: true);
        }
        await tester.tap(find.byTooltip(S.fillScreen));
        await tester.pump();
        expect(fit(), BoxFit.cover);
        await tester.tap(find.byTooltip(S.fitScreen));
        await tester.pump();
        expect(fit(), BoxFit.contain);
      },
    );

    videoTest('double taps move the song here too', (tester) async {
      final backend = await openVideo(tester);
      await openFull(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tapPicture(tester, 0.9, full: true);
      await tapPicture(tester, 0.9, full: true);
      expect(seeks(backend), [14000]);
    });

    videoTest('previous and next are there, and the name follows the song', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await openFull(tester);
      await tester.tap(find.byTooltip(S.nextSong));
      await tester.pump();
      expect(backend.calls, contains('next'));
      await tester.tap(find.byTooltip(S.previousSong));
      await tester.pump();
      expect(backend.calls, contains('prev'));
      backend.emit(StateEvent(sampleRoom(video: true, index: 1)));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(VideoFullScreen),
          matching: find.text('Song 1'),
        ),
        findsOneWidget,
      );
    });

    videoTest('it closes when the queue runs out', (tester) async {
      final backend = await openVideo(tester);
      await openFull(tester);
      backend.emit(
        StateEvent(sampleRoom(video: true, songs: 0, phase: 'idle')),
      );
      await settle(tester, 500);
      expect(find.byType(VideoFullScreen), findsNothing);
      expect(tester.takeException(), isNull);
      expect(lastOrientations(), isEmpty);
    });

    videoTest('it closes when another screen turns the picture off', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await openFull(tester);
      backend.emit(StateEvent(sampleRoom()));
      await settle(tester, 500);
      expect(find.byType(VideoFullScreen), findsNothing);
    });

    videoTest('a second touch on the button opens no second one', (
      tester,
    ) async {
      await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.fullScreen));
      await tester.pump();
      await openVideoFullScreen(
        tester.element(find.byType(PlaybackBar).first),
        lastRoom,
      );
      await settle(tester, 500);
      expect(find.byType(VideoFullScreen), findsOneWidget);
    });

    videoTest('the screen turned by the full screen opens no second one', (
      tester,
    ) async {
      await openVideo(tester);
      await openFull(tester);
      // The system turns the screen as it was asked to
      await resize(tester, 1200, 460);
      expect(find.byType(VideoFullScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await settle(tester, 500);
      expect(find.byType(VideoFullScreen), findsNothing);
      await resize(tester, 540, 1200);
      expect(find.byType(VideoFullScreen), findsNothing);
    });

    videoTest(
      'the full screen keeps the picture coming, in the background of the player too',
      (tester) async {
        final backend = await openVideo(tester);
        await openFull(tester);
        expect(find.byType(Texture), findsWidgets);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(
          backend.calls.lastWhere((c) => c.startsWith('videoVisible')),
          'videoVisible false',
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(
          backend.calls.lastWhere((c) => c.startsWith('videoVisible')),
          'videoVisible true',
        );
      },
    );
  });

  group('turning the phone', () {
    videoTest(
      'on its side while a video plays opens the whole screen, upright again closes it',
      (tester) async {
        await openVideo(tester);
        await resize(tester, 1200, 460);
        expect(find.byType(VideoFullScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Turned by hand: the screen is not held on its side
        expect(lastOrientations(), isNull);
        await resize(tester, 540, 1200);
        expect(find.byType(VideoFullScreen), findsNothing);
        expect(lastOrientations(), isEmpty);
        expect(find.byType(PlaybackBar), findsOneWidget);
        // And again
        await resize(tester, 1200, 460);
        expect(find.byType(VideoFullScreen), findsOneWidget);
      },
    );

    videoTest(
      'left by hand on its side, it stays in the player until turned again',
      (tester) async {
        await openVideo(tester);
        await resize(tester, 1200, 460);
        await tester.binding.handlePopRoute();
        await settle(tester, 500);
        expect(find.byType(VideoFullScreen), findsNothing);
        expect(tester.takeException(), isNull);
        // The player on its side, not a full screen that opens again by itself
        await settle(tester, 1000);
        expect(find.byType(VideoFullScreen), findsNothing);
        expect(find.byType(PlaybackBar), findsOneWidget);
        await resize(tester, 540, 1200);
        await resize(tester, 1200, 460);
        expect(find.byType(VideoFullScreen), findsOneWidget);
      },
    );

    videoTest('sound only, turning the phone just turns the player', (
      tester,
    ) async {
      recordSystem(tester);
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await settle(tester, 1000);
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      await resize(tester, 1200, 460);
      expect(find.byType(VideoFullScreen), findsNothing);
      expect(find.byType(PlaybackBar), findsOneWidget);
    });

    videoTest('with the player closed, turning the phone opens nothing', (
      tester,
    ) async {
      recordSystem(tester);
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(video: true)));
      await settle(tester, 1000);
      await resize(tester, 1200, 460);
      expect(find.byType(VideoFullScreen), findsNothing);
    });

    videoTest('a tablet turned keeps the picture beside the controls', (
      tester,
    ) async {
      await openVideo(tester, screen: const Size(800, 1280));
      await resize(tester, 1280, 800);
      expect(find.byType(VideoFullScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    videoTest('a panel open in the player does not stop it', (tester) async {
      await openVideo(tester);
      await tester.tap(find.byTooltip(S.upNext));
      await settle(tester, 400);
      await resize(tester, 1200, 460);
      expect(find.byType(VideoFullScreen), findsOneWidget);
    });
  });

  group('watching keeps the screen on and allows the small window', () {
    List<String> watching(FakeBackend backend) =>
        backend.calls.where((c) => c.startsWith('watching')).toList();

    videoTest('on while the picture shows and plays, off when paused', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      expect(watching(backend).last, 'watching true 1280x720');
      backend.emit(StateEvent(sampleRoom(video: true, phase: 'paused')));
      await tester.pump();
      expect(watching(backend).last, 'watching false 1280x720');
      backend.emit(StateEvent(sampleRoom(video: true)));
      await tester.pump();
      expect(watching(backend).last, 'watching true 1280x720');
    });

    videoTest('a stall in the middle does not let the screen go dark', (
      tester,
    ) async {
      final backend = await openVideo(
        tester,
        snapshot: sampleRoom(video: true, local: true),
      );
      // Outside a room, it is this phone's own player that says it plays
      backend.emit(PositionEvent(picture(1280, 720)));
      await tester.pump();
      final before = watching(backend).length;
      expect(watching(backend).last, startsWith('watching true'));
      backend.emit(
        PositionEvent(picture(1280, 720, playing: false, buffering: true)),
      );
      await tester.pump();
      // The next song, before its first frame
      backend.emit(
        PositionEvent(picture(0, 0, buffering: true, playing: false)),
      );
      await tester.pump();
      backend.emit(PositionEvent(picture(1280, 720)));
      await tester.pump();
      expect(
        watching(backend).skip(before),
        isEmpty,
        reason: 'nothing changed',
      );
    });

    videoTest('an upright picture gives an upright small window', (
      tester,
    ) async {
      final backend = await openVideo(tester, width: 720, height: 1280);
      expect(watching(backend).last, 'watching true 720x1280');
    });

    videoTest('off when the app goes to the background or the player closes', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(watching(backend).last, startsWith('watching true'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(watching(backend).last, startsWith('watching false'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(watching(backend).last, startsWith('watching true'));
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(watching(backend).last, startsWith('watching false'));
    });

    videoTest('never on for sound only', (tester) async {
      recordSystem(tester);
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(PositionEvent(picture(1280, 720)));
      await settle(tester, 1000);
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      expect(watching(backend).where((c) => c.contains('true')), isEmpty);
    });

    videoTest('held back here while the room plays on: off', (tester) async {
      final backend = await openVideo(tester);
      backend.emit(
        const PositionEvent(
          PlayerPosition(
            playing: false,
            heldBack: true,
            videoWidth: 1280,
            videoHeight: 720,
          ),
        ),
      );
      await tester.pump();
      expect(watching(backend).last, 'watching false 1280x720');
    });
  });

  group('the small window', () {
    videoTest('shows only the picture, and the app comes back as it was', (
      tester,
    ) async {
      final backend = await openVideo(tester);
      await tester.tap(find.byTooltip(S.upNext));
      await settle(tester, 400);
      backend.emit(const PipEvent(true));
      await tester.pump();
      // The small window is wide: the app underneath must not take it for a phone turned on its side
      await resize(tester, 240, 135);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pip-video')), findsOneWidget);
      expect(find.byType(VideoFullScreen), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('pip-video'))),
        const Rect.fromLTWH(0, 0, 240, 135),
      );
      // Nothing of the app is drawn or touched
      expect(find.byType(PlaybackBar, skipOffstage: true), findsNothing);

      await resize(tester, 540, 1200);
      backend.emit(const PipEvent(false));
      await tester.pump();
      await settle(tester, 300);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pip-video')), findsNothing);
      // Where it was: the player open on the queue
      expect(find.byType(PlaybackBar), findsOneWidget);
      expect(find.byTooltip(S.upNext), findsOneWidget);
      expect(find.byType(VideoFullScreen), findsNothing);
    });

    videoTest('from the whole screen too', (tester) async {
      final backend = await openVideo(tester);
      await tapPicture(tester, 0.5);
      await tester.tap(find.byTooltip(S.fullScreen));
      await settle(tester, 500);
      backend.emit(const PipEvent(true));
      await tester.pump();
      await resize(tester, 240, 135);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pip-video')), findsOneWidget);
      await resize(tester, 1200, 460);
      backend.emit(const PipEvent(false));
      await settle(tester, 300);
      expect(find.byType(VideoFullScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    videoTest('with nothing playing, it is black', (tester) async {
      recordSystem(tester);
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom(songs: 0, phase: 'idle')));
      await settle(tester, 500);
      backend.emit(const PipEvent(true));
      await tester.pump();
      expect(find.byKey(const ValueKey('pip-video')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('speed', () {
    videoTest('is not asked for in a room', (tester) async {
      final (backend, room) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump();
      await room.setPlaybackSpeed(1.5);
      expect(backend.calls, isNot(contains('speed 1.5')));
      backend.emit(StateEvent(sampleRoom(local: true)));
      await tester.pump();
      await room.setPlaybackSpeed(1.5);
      expect(backend.calls, contains('speed 1.5'));
    });
  });
}
