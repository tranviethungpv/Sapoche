import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/theme/accents.dart';
import 'package:sapoche/theme/palette.dart';

/// WCAG contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final (light, dark) = a.computeLuminance() > b.computeLuminance()
      ? (a, b)
      : (b, a);
  return (light.computeLuminance() + 0.05) / (dark.computeLuminance() + 0.05);
}

void main() {
  test('the quietest words of the light theme can still be read on its page and on the wash at its top', () {
    const p = Palette.light;
    for (final (name, color) in [
      ('textTertiary', p.textTertiary),
      ('success', p.success),
    ]) {
      for (final (where, background) in [
        ('base', p.base),
        ('washTop', p.washTop),
      ]) {
        expect(
          contrast(color, background),
          greaterThanOrEqualTo(4.5),
          reason: '$name on $where',
        );
      }
    }
  });

  test('pink, or no choice at all, is the palette the app was designed in', () {
    expect(Palette.forAccent(null, Brightness.light), same(Palette.light));
    expect(Palette.forAccent(null, Brightness.dark), same(Palette.dark));
    expect(
      Palette.forAccent(Palette.pinkAccent, Brightness.dark),
      same(Palette.dark),
    );
  });

  test('any colour picked keeps words readable in both themes', () {
    final picks = [
      // Pink is the palette as designed, which is not held to the same bar
      for (final (id, color) in accentPresets)
        if (id != 'pink') color,
      // The extremes a person can drag to: every hue at full strength, near white, near black and grey
      for (var h = 0; h < 360; h += 15)
        HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
      for (var h = 0; h < 360; h += 60) ...[
        HSVColor.fromAHSV(1, h.toDouble(), 0.1, 1).toColor(),
        HSVColor.fromAHSV(1, h.toDouble(), 1, 0.15).toColor(),
        HSVColor.fromAHSV(1, h.toDouble(), 0, 0.5).toColor(),
      ],
      const Color(0xFFFFFF00),
      const Color(0xFF000000),
      const Color(0xFFFFFFFF),
    ];
    for (final color in picks) {
      for (final brightness in Brightness.values) {
        final p = Palette.forAccent(color, brightness);
        final id = '${color.toARGB32().toRadixString(16)} $brightness';
        expect(p.accent, color);
        expect(
          contrast(p.primary, p.base),
          greaterThanOrEqualTo(4.5),
          reason: 'primary $id',
        );
        expect(
          contrast(p.onPrimary, p.primary),
          greaterThanOrEqualTo(4.5),
          reason: 'onPrimary $id',
        );
        expect(
          contrast(p.onPrimaryContainer, p.primaryContainer),
          greaterThanOrEqualTo(7),
          reason: 'onPrimaryContainer $id',
        );
        for (final (name, text) in [
          ('text', p.text),
          ('textSecondary', p.textSecondary),
          ('textTertiary', p.textTertiary),
        ]) {
          expect(
            contrast(text, p.base),
            greaterThanOrEqualTo(4.5),
            reason: '$name on base $id',
          );
          expect(
            contrast(text, p.washTop),
            greaterThanOrEqualTo(4.5),
            reason: '$name on washTop $id',
          );
        }
        expect(
          contrast(p.onSnack, p.snack),
          greaterThanOrEqualTo(7),
          reason: 'snack $id',
        );
      }
    }
  });

  test('a colour takes the hue of the pick through the whole palette', () {
    final blue = Palette.forAccent(const Color(0xFF2F6FDE), Brightness.light);
    for (final color in [
      blue.washTop,
      blue.surfaceRaised,
      blue.menu,
      blue.outline,
    ]) {
      final hue = HSLColor.fromColor(color).hue;
      expect(hue, closeTo(HSLColor.fromColor(const Color(0xFF2F6FDE)).hue, 3));
    }
  });
}
