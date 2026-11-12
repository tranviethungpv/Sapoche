import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/cover_glow.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';

import 'cover_glow_test.dart' show painted, solid;

/// WCAG 2.x contrast of [fg] drawn over [bg] (a see-through [fg] is mixed with it first, as it is on screen).
double contrast(Color fg, Color bg) {
  final top = Color.alphaBlend(fg, bg);
  final a = top.computeLuminance(), b = bg.computeLuminance();
  final hi = a > b ? a : b, lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  /// The pictures the full player lays down behind everything: [CoverGlow.render] of covers from black to white and
  /// of every hue at full strength, in each theme. Every pixel is a ground the words and icons can land on.
  Future<List<Color>> grounds({required bool light}) async {
    final covers = <ui.Image>[
      for (final rgb in const [
        [0, 0, 0],
        [255, 255, 255],
        [128, 128, 128],
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [255, 255, 0],
        [0, 255, 255],
        [255, 0, 255],
        [255, 128, 0],
        [40, 40, 90],
      ])
        await solid(rgb[0], rgb[1], rgb[2]),
      // A cover of two halves: the glow is made of patches, and a bright one can sit next to a deep one
      await painted((x, y) => x < 24 ? [255, 255, 255] : [0, 0, 120]),
    ];
    final out = <Color>[];
    for (final cover in covers) {
      final glow = await CoverGlow.render(cover, light: light);
      final data = (await glow.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      for (var i = 0; i < data.lengthInBytes; i += 4 * 7) {
        final ground = Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        );
        // The veil over it is at least this much; the page's gradient only makes it stronger
        out.add(
          light ? ground : Color.alphaBlend(PlayerBackdrop.darkestVeil, ground),
        );
      }
    }
    return out;
  }

  for (final light in [true, false]) {
    final name = light ? 'light' : 'dark';
    final onCover = (light ? Palette.light : Palette.dark).onCover;

    testWidgets('on the colours of a cover, words keep 4.5:1 ($name)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        var worst = double.infinity;
        for (final ground in await grounds(light: light)) {
          final c = contrast(onCover.textSecondary, ground);
          if (c < worst) worst = c;
        }
        expect(worst, greaterThanOrEqualTo(4.5));
      });
    });

    testWidgets(
      'on the colours of a cover, a name that is a link keeps 4.5:1 ($name)',
      (tester) async {
        await tester.runAsync(() async {
          final base = light ? Palette.light : Palette.dark;
          var worst = double.infinity;
          for (final ground in await grounds(light: light)) {
            final c = contrast(base.link, ground);
            if (c < worst) worst = c;
          }
          expect(worst, greaterThanOrEqualTo(4.5));
        });
      },
    );

    testWidgets('on the colours of a cover, icons keep 3:1 ($name)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        var worst = double.infinity;
        for (final ground in await grounds(light: light)) {
          final c = contrast(onCover.textTertiary, ground);
          if (c < worst) worst = c;
        }
        expect(worst, greaterThanOrEqualTo(3));
      });
    });
  }

  test('only the quiet colours change on a cover', () {
    final p = Palette.light;
    expect(p.onCover.text, p.text);
    expect(p.onCover.primary, p.primary);
    expect(p.onCover.base, p.base);
    expect(p.onCover.textSecondary, isNot(p.textSecondary));
  });
}
