// The camera of `docs/plans/2026-11-12-ui-fixed-yardstick.md` (K0): draws every screen of `shot_screens.dart` at every
// window of `shot_harness.dart` from one fixed set of data (`shot_data.dart`), and writes the pictures to a folder.
//
//   SHOTS_OUT=/some/folder flutter test test/shots/shots_test.dart
//   SHOTS_MATRIX=quick|base|full   which windows (default base); SHOTS_ONLY=player,album   which screens
//
// Without SHOTS_OUT it does nothing, so that `flutter test` stays quick.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sapoche/strings.dart';
import 'shot_audit.dart';
import 'shot_harness.dart';
import 'shot_screens.dart';

void main() {
  final out = Platform.environment['SHOTS_OUT'];
  if (out == null) {
    test('draws the pictures', () {}, skip: 'set SHOTS_OUT to draw them');
    return;
  }
  final only = Platform.environment['SHOTS_ONLY']?.split(',');
  final dir = Directory(out)..createSync(recursive: true);

  final audit = StringBuffer();
  final counts = <String, int>{};
  tearDownAll(() {
    File('${dir.path}/audit.txt').writeAsStringSync(audit.toString());
    stdout.writeln('audit: ${counts.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  });

  setUpAll(() async {
    await loadFonts();
    goldenFileComparator = FolderWriter(dir);
  });

  for (final screen in shotScreens) {
    if (only != null && !only.contains(screen.id)) continue;
    for (final combo in combos()) {
      if (screen.only != null && !screen.only!(combo)) continue;
      testWidgets('${screen.id} ${combo.name}', (tester) async {
        final catcher = ErrorCatcher()..start();
        final semantics = tester.ensureSemantics();
        try {
          await pumpShot(tester, screen, combo);
          await expectLater(find.byType(MaterialApp).first, matchesGoldenFile('${screen.id}__${combo.name}.png'));
          final lines = [
            for (final e in catcher.overflows) 'overflow: $e',
            ...sortAudit(auditText(tester, {S.tabHome, S.tabLibrary, S.tabListen, S.tabRoom})),
            ...await auditGuidelines(tester),
          ];
          for (final l in lines) {
            audit.writeln('${screen.id} ${combo.name} $l');
            counts.update(l.split(':').first, (n) => n + 1, ifAbsent: () => 1);
          }
        } finally {
          catcher.stop();
          semantics.dispose();
        }
      });
    }
  }
}
