import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/theme/accents.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_app.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the colour is remembered, and pink is stored as nothing', () async {
    var settings = await AppSettings.load();
    expect(settings.accent, isNull);
    settings.accent = const Color(0xFF2F6FDE);
    settings = await AppSettings.load();
    expect(settings.accent, const Color(0xFF2F6FDE));
    settings.accent = null;
    settings = await AppSettings.load();
    expect(settings.accent, isNull);
  });

  test('a preset is told from a colour of the person\'s own', () {
    expect(accentPresetId(null), 'pink');
    expect(accentPresetId(const Color(0xFF2E7D4F)), 'green');
    expect(accentPresetId(const Color(0xFF123456)), isNull);
  });

  AppSettings settingsOf(WidgetTester tester) =>
      AppScope.of(tester.element(find.byKey(const ValueKey('accent-blue'))))
          .settings;

  testWidgets('a swatch in Appearance repaints the whole app', (tester) async {
    await pumpApp(tester);
    await openTopic(tester, 'appearance');
    Color primary() =>
        Theme.of(tester.element(find.byKey(const ValueKey('accent-blue'))))
            .colorScheme
            .primary;
    expect(primary(), Palette.light.primary);
    await tester.tap(find.byKey(const ValueKey('accent-blue')));
    await tester.pumpAndSettle();
    expect(settingsOf(tester).accent, const Color(0xFF2F6FDE));
    expect(primary(), isNot(Palette.light.primary));
    await tester.tap(find.byKey(const ValueKey('accent-pink')));
    await tester.pumpAndSettle();
    expect(settingsOf(tester).accent, isNull);
    expect(primary(), Palette.light.primary);
  });

  testWidgets('the circle for a colour of one\'s own opens the picker', (
    tester,
  ) async {
    await pumpApp(tester);
    await openTopic(tester, 'appearance');
    await tester.tap(find.byKey(const ValueKey('accent-custom')));
    await tester.pumpAndSettle();
    // Drag the hue to the far end of its track and brightness halfway
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('accent-hue'))) +
          const Offset(80, 0),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('accent-use')));
    await tester.pumpAndSettle();
    final picked = settingsOf(tester).accent;
    expect(picked, isNotNull);
    expect(accentPresetId(picked), isNull);
    // The circle of its own now wears the colour
    expect(find.byKey(const ValueKey('accent-custom')), findsOneWidget);
  });
}
