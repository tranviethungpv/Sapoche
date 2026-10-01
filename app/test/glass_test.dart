import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/theme/palette.dart';
import 'package:unison/ui/widgets/glass.dart';

void main() {
  for (final p in [Palette.light, Palette.dark]) {
    testWidgets('every kind of glass draws in ${p.brightness.name} mode', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                for (final (dense, floating, solid, tint) in [
                  (false, false, false, null),
                  (true, true, false, null),
                  (false, false, false, p.primaryContainer),
                  (false, true, true, p.primary),
                ])
                  DecoratedBox(
                    decoration: GlassDecoration.of(
                      p,
                      radius: 20,
                      dense: dense,
                      floating: floating,
                      solid: solid,
                      tint: tint,
                    ),
                    child: const SizedBox(width: 80, height: 60),
                  ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('a touch in the rounded corner is outside the pane', () {
    final glass = GlassDecoration.of(Palette.light, radius: 30);
    const size = Size(100, 100);
    expect(glass.hitTest(size, const Offset(50, 50)), isTrue);
    expect(glass.hitTest(size, const Offset(1, 1)), isFalse);
  });

  test('equal panes are equal, different ones are not', () {
    expect(
      GlassDecoration.of(Palette.light, dense: true),
      GlassDecoration.of(Palette.light, dense: true),
    );
    expect(
      GlassDecoration.of(Palette.light, dense: true) ==
          GlassDecoration.of(Palette.light, dense: false),
      isFalse,
    );
    expect(
      GlassDecoration.of(Palette.light) == GlassDecoration.of(Palette.dark),
      isFalse,
    );
  });
}
