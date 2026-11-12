import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/strings.dart';

import '../fake_backend.dart';
import '../pump_app.dart';

/// One window the picture set is drawn in: the five sizes of the plan, `docs/plans/2026-11-12-ui-fixed-yardstick.md` K0.
class ShotSize {
  const ShotSize(this.name, this.width, this.height, {this.dpr = 2, this.bottom = 0});

  final String name;
  final double width;
  final double height;
  final double dpr;

  /// The system's own bar under the app (the home indicator), in dp.
  final double bottom;
}

const shotSizes = [
  ShotSize('w360', 360, 800),
  ShotSize('w411', 411, 914),
  ShotSize('w393', 393, 852, bottom: 34),
  ShotSize('w1280', 1280, 800, dpr: 1),
  ShotSize('w1440', 1440, 900, dpr: 1),
];

/// One way the app can be set: size, theme, language, text size.
class ShotCombo {
  const ShotCombo(this.size, {this.dark = false, this.vi = false, this.text = 1.0});

  final ShotSize size;
  final bool dark;
  final bool vi;
  final double text;

  String get name =>
      '${size.name}-${dark ? 'dark' : 'light'}-${vi ? 'vi' : 'en'}${text == 1.0 ? '' : '-x$text'}';

  bool get wide => size.width >= 600;
}

/// One screen of the app, and the steps that get to it. [prepare] runs before the app is built, for what the native side
/// knows; [open] runs when it is up.
class ShotScreen {
  const ShotScreen(
    this.id,
    this.open, {
    this.prepare,
    this.listen = false,
    this.only,
  });

  final String id;
  final Future<void> Function(WidgetTester tester, FakeBackend backend) open;
  final void Function(FakeBackend backend)? prepare;
  final bool listen;

  /// When the screen only exists on some windows, e.g. only the wide ones.
  final bool Function(ShotCombo combo)? only;
}

/// The combos to draw: `SHOTS_MATRIX=base` (the default: five sizes, light and dark, English), `full` (all of the plan:
/// also Vietnamese and text at 1.3), `quick` (one phone and one wide window, light, English).
List<ShotCombo> combos() {
  final mode = Platform.environment['SHOTS_MATRIX'] ?? 'base';
  if (mode == 'quick') {
    return [ShotCombo(shotSizes[1]), ShotCombo(shotSizes[3])];
  }
  return [
    for (final size in shotSizes)
      for (final dark in [false, true])
        for (final vi in mode == 'full' ? [false, true] : [false])
          for (final text in mode == 'full' ? [1.0, 1.3] : [1.0])
            ShotCombo(size, dark: dark, vi: vi, text: text),
  ];
}

/// Writes the pictures to a folder instead of comparing them with ones kept: this is a camera, not a test of pixels.
class FolderWriter extends GoldenFileComparator {
  FolderWriter(this.dir);

  final Directory dir;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    File('${dir.path}/${golden.pathSegments.last}').writeAsBytesSync(imageBytes);
    return true;
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}

Future<void> loadFonts() async {
  final inter = FontLoader('Inter')
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter.ttf').readAsBytesSync())));
  await inter.load();
  // The icons: the SDK's own font, so that a button is a button and not an empty box
  final flutter = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/share/flutter';
  final icons = File('$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

/// Sets the window and builds the app on [screen] for [combo]. Returns the backend for the steps after.
Future<FakeBackend> pumpShot(WidgetTester tester, ShotScreen screen, ShotCombo combo) async {
  final (backend, _) = await pumpApp(
    tester,
    mode: combo.dark ? ThemeMode.dark : ThemeMode.light,
    prefs: {if (combo.vi) 'language': 'vi'},
    listen: screen.listen,
    prepare: screen.prepare,
  );
  final size = combo.size;
  tester.view
    ..devicePixelRatio = size.dpr
    ..physicalSize = Size(size.width * size.dpr, size.height * size.dpr)
    ..padding = FakeViewPadding(bottom: size.bottom * size.dpr)
    ..viewPadding = FakeViewPadding(bottom: size.bottom * size.dpr);
  tester.platformDispatcher.textScaleFactorTestValue = combo.text;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  S.current = combo.vi ? 'vi' : 'en';
  await tester.pump();
  await screen.open(tester, backend);
  return backend;
}

/// Lets what fades in, fade in.
Future<void> settleShot(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}
