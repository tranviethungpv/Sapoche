import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/chat_theme.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/chat_look.dart';

import 'chat_test.dart' show history, message;
import 'fake_backend.dart';
import 'png_fixture.dart';
import 'pump_app.dart';

/// The bytes of a picture of one colour, as the decoder hands them out: red, green, blue, alpha.
Uint8List flat(List<int> rgb, {int pixels = 100}) => Uint8List.fromList([
  for (var i = 0; i < pixels; i++) ...[...rgb, 255],
]);

/// The bytes of a decoded picture as red, green, blue and alpha for each pixel, as [ChatTheme.standOut] reads them.
Uint8List rgbaOf(Uint8List jpeg) {
  final picture = img.decodeJpg(jpeg)!;
  return Uint8List.fromList([
    for (final px in picture) ...[
      px.r.toInt(),
      px.g.toInt(),
      px.b.toInt(),
      255,
    ],
  ]);
}

/// Lets what is done off the screen (reading a photo, cutting it) finish: it takes real time, and the frames in between
/// are pumped by hand, as a wheel that turns in the meantime keeps the screen from ever being still.
Future<void> realTime(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  await tester.pumpAndSettle();
}

double contrastWithWhite(Color c) => 1.05 / (c.computeLuminance() + 0.05);

void main() {
  group('a theme is an id the room keeps', () {
    test('the default, a name nobody knows and rubbish are no theme', () {
      expect(ChatTheme.parse(null), isNull);
      expect(ChatTheme.parse('default'), isNull);
      expect(ChatTheme.parse('from-the-future'), isNull);
      expect(ChatTheme.parse('c-12'), isNull);
      expect(ChatTheme.parse('c-gggggg-000000'), isNull);
    });

    test(
      'a preset is found by its id, and every id is one the server accepts',
      () {
        final shape = RegExp(r'^[a-z0-9-]{1,24}$');
        for (final preset in ChatTheme.presets) {
          expect(ChatTheme.parse(preset.id)?.from, preset.from);
          expect(shape.hasMatch(preset.id), isTrue, reason: preset.id);
        }
      },
    );

    test('colours from a photo make an id that gives the colours back', () {
      final made = ChatTheme.custom(
        const Color(0xFF1E88E5),
        const Color(0xFFD81B60),
      );
      expect(made.id, 'c-1e88e5-d81b60');
      expect(RegExp(r'^[a-z0-9-]{1,24}$').hasMatch(made.id), isTrue);
      final back = ChatTheme.parse(made.id)!;
      expect(back.from, const Color(0xFF1E88E5));
      expect(back.to, const Color(0xFFD81B60));
    });
  });

  group('the colours that stand out in a photo', () {
    double hueOf(Color c) => HSVColor.fromColor(c).hue;

    test('a red photo gives red, and something near it for the second', () {
      final (a, b) = ChatTheme.standOut(flat([220, 30, 30]));
      expect(hueOf(a), anyOf(lessThan(15), greaterThan(345)));
      expect((hueOf(b) - hueOf(a)).abs(), lessThan(60));
    });

    test('two colours in a photo give both, the larger first', () {
      final bytes = Uint8List.fromList([
        ...flat([30, 90, 220], pixels: 70),
        ...flat([240, 200, 20], pixels: 30),
      ]);
      final (a, b) = ChatTheme.standOut(bytes);
      expect(hueOf(a), inInclusiveRange(200, 240));
      expect(hueOf(b), inInclusiveRange(40, 65));
    });

    test('a big grey sky does not outweigh a small red kite', () {
      final bytes = Uint8List.fromList([
        ...flat([128, 128, 128], pixels: 90),
        ...flat([220, 30, 30], pixels: 10),
      ]);
      final (a, _) = ChatTheme.standOut(bytes);
      expect(hueOf(a), anyOf(lessThan(15), greaterThan(345)));
    });

    test(
      'a photo with no colour gives greys, and nothing at all does not throw',
      () {
        final (a, b) = ChatTheme.standOut(flat([120, 120, 120]));
        expect(HSVColor.fromColor(a).saturation, lessThan(0.1));
        expect(b, isNot(a));
        expect(() => ChatTheme.standOut(Uint8List(0)), returnsNormally);
      },
    );

    testWidgets('a picture is read, and bytes that are no picture are not', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final made = await ChatTheme.fromPhoto(solidPng(30, 120, 220));
        expect(made, isNotNull);
        expect(made!.id, startsWith('c-'));
        expect(
          await ChatTheme.fromPhoto(Uint8List.fromList([1, 2, 3])),
          isNull,
        );
      });
    });
  });

  group('the look of a theme', () {
    test(
      'white words can be read on every theme, in the light and in the dark',
      () {
        final themes = [
          ...ChatTheme.presets,
          ChatTheme.custom(const Color(0xFFFFEB3B), const Color(0xFFFFF59D)),
        ];
        for (final palette in [Palette.light, Palette.dark]) {
          for (final theme in themes) {
            final look = ChatLook.of(theme.id, palette)!;
            for (final color in (look.mine as LinearGradient).colors) {
              expect(
                contrastWithWhite(color),
                greaterThanOrEqualTo(4.5),
                reason: '${theme.id} ${palette.brightness}',
              );
            }
          }
        }
      },
    );

    test('no theme keeps the colours of the app', () {
      expect(ChatLook.of(null, Palette.light), isNull);
      expect(ChatLook.of('default', Palette.dark), isNull);
      expect(ChatLook.of('nobody-knows', Palette.dark), isNull);
    });
  });

  group('the picture cut for the room', () {
    final tall = bandsPng(180, 320, [
      [220, 30, 30],
      [30, 60, 220],
    ]);

    test(
      'the part asked for is what is cut, as a picture the room can take',
      () {
        final top = cutWallpaper(tall, left: 0, top: 0, width: 1, height: 0.4)!;
        final (a, _) = ChatTheme.standOut(rgbaOf(top));
        expect(
          HSVColor.fromColor(a).hue,
          anyOf(lessThan(15), greaterThan(345)),
          reason: 'the red half',
        );
        final foot = cutWallpaper(
          tall,
          left: 0,
          top: 0.6,
          width: 1,
          height: 0.4,
        )!;
        expect(
          HSVColor.fromColor(ChatTheme.standOut(rgbaOf(foot)).$1).hue,
          inInclusiveRange(215, 245),
        );
      },
    );

    test('a busy picture is made small enough to be sent, still the shape of the frame', () {
      final noise = Random(7);
      final busy = img.Image(width: 1200, height: 2000);
      for (final pixel in busy) {
        pixel
          ..r = noise.nextInt(256)
          ..g = noise.nextInt(256)
          ..b = noise.nextInt(256);
      }
      final cut = cutWallpaper(
        Uint8List.fromList(img.encodePng(busy)),
        left: 0,
        top: 0,
        width: 1,
        height: 1,
      )!;
      expect(base64Encode(cut).length, lessThanOrEqualTo(maxWallpaperChars));
      final back = img.decodeJpg(cut)!;
      expect(back.width / back.height, closeTo(1200 / 2000, 0.01));
      expect(back.width, lessThanOrEqualTo(540));
    });

    test('bytes that are no picture give nothing, and a photo is turned upright and shrunk', () {
      expect(
        cutWallpaper(
          Uint8List.fromList([1, 2, 3]),
          left: 0,
          top: 0,
          width: 1,
          height: 1,
        ),
        isNull,
      );
      expect(uprightPhoto(Uint8List.fromList([1, 2, 3])), isNull);
      final big = Uint8List.fromList(
        img.encodePng(img.Image(width: 3200, height: 2000)),
      );
      final small = img.decodeJpg(uprightPhoto(big)!)!;
      expect(small.width, wallpaperPickSide);
      expect(small.height, closeTo(1000, 1));
    });
  });

  group('choosing the look of the chat', () {
    Future<FakeBackend> openChat(
      WidgetTester tester, {
      String? theme = 'default',
      GuestControl guestControl = GuestControl.all,
      String? ownerId,
      Future<Uint8List?> Function()? wallpaper,
    }) async {
      final (backend, _) = await pumpApp(tester, wallpaperPicker: wallpaper);
      backend.emit(
        StateEvent(
          sampleRoom(
            theme: theme,
            guestControl: guestControl,
            ownerId: ownerId,
            members: [
              Member(
                id: 'me',
                name: 'Anna',
                ready: true,
                owner: ownerId == 'me',
              ),
              Member(id: 'b', name: 'Binh', ready: true, owner: ownerId == 'b'),
            ],
          ),
        ),
      );
      backend.emit(history([message(1, 'b', 'hello'), message(2, 'me', 'hi')]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('a server too old to have themes gets no button', (
      tester,
    ) async {
      await openChat(tester, theme: null);
      expect(find.byKey(const ValueKey('chat-theme')), findsNothing);
    });

    testWidgets('a touch on a look is the choice, and the room hears it', (
      tester,
    ) async {
      final backend = await openChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-theme')));
      await tester.pumpAndSettle();
      expect(find.text(S.chatThemeShared), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-theme-ocean')));
      await tester.pump();
      expect(backend.calls.last, 'roomTheme ocean');

      await tester.tap(find.byKey(const ValueKey('chat-theme-default')));
      await tester.pump();
      expect(backend.calls.last, 'roomTheme default');
    });

    testWidgets(
      'the chat takes the look the room has, and loses it when the room does',
      (tester) async {
        final backend = await openChat(tester);
        ChatLook? shown() =>
            tester.widget<ChatLookScope>(find.byType(ChatLookScope)).look;
        expect(shown(), isNull);

        backend.emit(StateEvent(sampleRoom(theme: 'sunset')));
        await tester.pumpAndSettle();
        expect(shown(), isNotNull);

        backend.emit(StateEvent(sampleRoom(theme: 'default')));
        await tester.pumpAndSettle();
        expect(shown(), isNull);
      },
    );

    testWidgets('an id this version does not know leaves the app colours', (
      tester,
    ) async {
      await openChat(tester, theme: 'from-the-future');
      expect(
        tester.widget<ChatLookScope>(find.byType(ChatLookScope)).look,
        isNull,
      );
    });

    testWidgets(
      'a guest of a restricted room sees the looks but cannot choose one',
      (tester) async {
        final backend = await openChat(
          tester,
          guestControl: GuestControl.add,
          ownerId: 'b',
        );
        await tester.tap(find.byKey(const ValueKey('chat-theme')));
        await tester.pumpAndSettle();
        expect(find.text(S.chatThemeLocked), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('chat-theme-ocean')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(backend.calls.where((c) => c.startsWith('roomTheme')), isEmpty);
      },
    );

    /// Opens the picker of a photo from the theme sheet and waits for the photo to be read.
    Future<void> pickPhoto(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-theme')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-theme-photo')));
      await realTime(tester);
    }

    /// Presses Use, and waits for the picture to be cut and its colours read.
    Future<void> use(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('wallpaper-use')));
      await realTime(tester);
    }

    testWidgets(
      'a photo is placed in the frame before it is used, and goes to the room with its colours',
      (tester) async {
        final backend = await openChat(
          tester,
          wallpaper: () async => bandsPng(180, 320, [
            [30, 90, 220],
          ]),
        );
        await pickPhoto(tester);
        expect(find.byKey(const ValueKey('wallpaper-frame')), findsOneWidget);
        expect(
          find.text(S.wallpaperSample1),
          findsOneWidget,
          reason: 'the blend is shown as the chat will have it',
        );
        expect(
          backend.calls.where((c) => c.startsWith('roomTheme')),
          isEmpty,
          reason: 'nothing goes before Use',
        );

        await use(tester);
        final sent = backend.calls.where((c) => c.startsWith('roomTheme'));
        expect(sent, hasLength(1));
        expect(
          sent.single,
          matches(
            RegExp(r'^roomTheme c-[0-9a-f]{6}-[0-9a-f]{6} \+background$'),
          ),
        );
        expect(
          find.byKey(const ValueKey('wallpaper-frame')),
          findsNothing,
          reason: 'the editor closes',
        );
      },
    );

    testWidgets('backing out of the frame sends nothing', (tester) async {
      final backend = await openChat(
        tester,
        wallpaper: () async => bandsPng(180, 320, [
          [30, 90, 220],
        ]),
      );
      await pickPhoto(tester);
      await tester.tap(find.byKey(const ValueKey('wallpaper-cancel')));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('roomTheme')), isEmpty);
    });

    testWidgets('a photo that is no picture says so and cannot be used', (
      tester,
    ) async {
      final backend = await openChat(
        tester,
        wallpaper: () async => Uint8List.fromList([1, 2, 3]),
      );
      await pickPhoto(tester);
      expect(find.text(S.chatThemeUnreadable), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('wallpaper-use')))
            .onPressed,
        isNull,
      );
      expect(backend.calls.where((c) => c.startsWith('roomTheme')), isEmpty);
    });

    testWidgets(
      'zooming in takes the middle of the photo, and the colours of what is in the frame',
      (tester) async {
        // A tall photo of a red top, a green middle and a blue foot: the frame has all three until it is zoomed in
        final backend = await openChat(
          tester,
          wallpaper: () async => bandsPng(180, 320, [
            [220, 30, 30],
            [30, 200, 60],
            [30, 60, 220],
          ]),
        );
        await pickPhoto(tester);
        await tester.drag(
          find.byKey(const ValueKey('wallpaper-zoom')),
          const Offset(2000, 0),
        );
        await tester.pumpAndSettle();
        await use(tester);
        final id = backend.calls
            .firstWhere((c) => c.startsWith('roomTheme'))
            .split(' ')[1];
        final theme = ChatTheme.parse(id)!;
        expect(
          HSVColor.fromColor(theme.from).hue,
          inInclusiveRange(100, 150),
          reason: 'green',
        );
      },
    );

    testWidgets(
      'the chat shows the photo the room has behind it, and loses it with the room',
      (tester) async {
        final backend = await openChat(tester);
        backend.emit(StateEvent(sampleRoom(theme: 'c-1e88e5-d81b60')));
        backend.emit(
          AvatarEvent(
            RoomController.backgroundId,
            solidPng(30, 90, 220, side: 64),
          ),
        );
        await tester.pumpAndSettle();
        ChatLook? shown() =>
            tester.widget<ChatLookScope>(find.byType(ChatLookScope)).look;
        expect(shown()?.picture, isNotNull);

        backend.emit(AvatarEvent(RoomController.backgroundId, null));
        await tester.pumpAndSettle();
        expect(shown(), isNotNull, reason: 'the colours stay');
        expect(shown()?.picture, isNull);
      },
    );

    testWidgets('another look than the photo takes the photo away', (
      tester,
    ) async {
      final backend = await openChat(tester);
      backend.emit(StateEvent(sampleRoom(theme: 'c-1e88e5-d81b60')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-theme')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-theme-ocean')));
      await tester.pump();
      expect(
        backend.calls.last,
        'roomTheme ocean',
        reason: 'no +background: the null clears it',
      );
    });
  });
}
