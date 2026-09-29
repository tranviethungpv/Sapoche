import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/ui/cover_color.dart';

Uint8List pixels(List<Color> colors) => Uint8List.fromList([
  for (final c in colors) ...[
    (c.r * 255).round(),
    (c.g * 255).round(),
    (c.b * 255).round(),
    255,
  ],
]);

void main() {
  test('a plainly coloured cover gives that colour', () {
    final color = CoverColor.fromPixels(
      pixels(List.filled(100, const Color(0xFFCC3355))),
    );
    expect(color, const Color(0xFFCC3355));
  });

  test('a small vivid detail on a white cover still wins', () {
    final color = CoverColor.fromPixels(
      pixels([
        ...List.filled(90, const Color(0xFFFFFFFF)),
        ...List.filled(10, const Color(0xFF2F80C0)),
      ]),
    );
    expect(color, const Color(0xFF2F80C0));
  });

  test('grey, black and white covers have no colour to offer', () {
    expect(
      CoverColor.fromPixels(pixels(List.filled(100, const Color(0xFF808080)))),
      isNull,
    );
    expect(
      CoverColor.fromPixels(pixels(List.filled(100, const Color(0xFF000000)))),
      isNull,
    );
    expect(
      CoverColor.fromPixels(pixels(List.filled(100, const Color(0xFFFFFFFF)))),
      isNull,
    );
  });

  test('transparent pixels are ignored', () {
    final rgba = Uint8List.fromList([255, 0, 0, 0, 0, 0, 255, 255]);
    expect(CoverColor.fromPixels(rgba), const Color(0xFF0000FF));
  });
}
