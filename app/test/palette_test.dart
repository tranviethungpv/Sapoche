import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
