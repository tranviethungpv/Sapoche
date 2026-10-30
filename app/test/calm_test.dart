import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/shimmer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_app.dart';

void main() {
  tearDown(() {
    Calm.chosen = null;
    Calm.weak = false;
    Calm.warm = false;
  });

  group('Calm', () {
    test('is off for a phone that is cool, strong and left alone', () {
      expect(Calm.on.value, isFalse);
      expect(Calm.light.value, isFalse);
    });

    test('is on while the phone is warm, without being a setting', () {
      Calm.warm = true;
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isFalse);
      Calm.warm = false;
      expect(Calm.on.value, isFalse);
    });

    test('is on for a weak phone until the person says otherwise', () {
      Calm.weak = true;
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isTrue);
      Calm.chosen = false;
      expect(Calm.on.value, isFalse);
      expect(Calm.light.value, isFalse);
      Calm.chosen = null;
      expect(Calm.light.value, isTrue);
    });

    test('is on when the person chose it, whatever the phone', () {
      Calm.chosen = true;
      expect(Calm.on.value, isTrue);
      Calm.warm = true;
      Calm.chosen = false;
      // Still warm: the choice is about the setting, not about the heat
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isFalse);
    });

    test(
      'the native side says whether the phone is weak along with the heat',
      () {
        final event = const CalmEvent(false, weak: true);
        expect(event.weak, isTrue);
        expect(const CalmEvent(true).weak, isFalse);
      },
    );
  });

  testWidgets('loading rows stand still while the effects are light', (
    tester,
  ) async {
    Calm.chosen = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Palette.light),
        home: const Scaffold(body: SkeletonList()),
      ),
    );
    // A sweep that goes on for ever would never let this settle
    await tester.pumpAndSettle();
    Calm.chosen = false;
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    Calm.chosen = true;
    await tester.pump();
    await tester.pumpAndSettle();
  });

  group('the setting', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('is remembered, and loaded into Calm', () async {
      var settings = await AppSettings.load();
      expect(settings.lightEffects, isNull);
      settings.lightEffects = true;
      expect(Calm.light.value, isTrue);
      settings = await AppSettings.load();
      expect(settings.lightEffects, isTrue);
      Calm.chosen = null;
      settings = await AppSettings.load();
      expect(Calm.light.value, isTrue);
      settings.lightEffects = null;
      expect(Calm.light.value, isFalse);
    });

    testWidgets('is a switch in Appearance that shows what is in force', (
      tester,
    ) async {
      await pumpApp(tester);
      await openTopic(tester, 'appearance');
      Switch toggle() => tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const ValueKey('light-effects')),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle().value, isFalse);
      await tester.tap(find.byKey(const ValueKey('light-effects')));
      await tester.pumpAndSettle();
      expect(toggle().value, isTrue);
      expect(Calm.on.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('light-effects')));
      await tester.pumpAndSettle();
      expect(Calm.on.value, isFalse);
    });

    testWidgets('a weak phone starts with it on', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const CalmEvent(false, weak: true));
      await tester.pumpAndSettle();
      expect(Calm.light.value, isTrue);
    });
  });
}
