import 'package:flutter/material.dart';

/// Colour tokens. The look is a pale pink veil laid over plain white (light) or near black (dark);
/// every other colour is derived from that pink so nothing fights with it.
class Palette {
  const Palette._({
    required this.brightness,
    required this.base,
    required this.washTop,
    required this.washMid,
    required this.surface,
    required this.surfaceRaised,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.outline,
    required this.outlineSoft,
    required this.error,
    required this.success,
    required this.menu,
    required this.dialog,
    required this.sheet,
    required this.snack,
    required this.onSnack,
    this.accent,
  });

  final Brightness brightness;

  /// Plain background colour under the veil.
  final Color base;

  /// The veil: pink at the top of the screen fading into [base].
  final Color washTop;
  final Color washMid;

  final Color surface;
  final Color surfaceRaised;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color outline;
  final Color outlineSoft;
  final Color error;
  final Color success;

  /// Pop-up menus, dialogs, bottom sheets and the snack bar sit on their own tinted ground.
  final Color menu;
  final Color dialog;
  final Color sheet;
  final Color snack;
  final Color onSnack;

  /// The colour the person picked this palette from; null for the pink the app was designed with.
  final Color? accent;

  /// The see-through fill of what sits on a page's backdrop (groups of settings, the search field, filters, round
  /// buttons): the soft tint of the glass bars without their blur, so the cover's colours show through it.
  Color get veil =>
      text.withValues(alpha: brightness == Brightness.light ? 0.05 : 0.07);

  /// The same, stronger: what is chosen among things on a veil.
  Color get veilStrong =>
      text.withValues(alpha: brightness == Brightness.light ? 0.08 : 0.10);

  /// The empty part of a bar that fills as it goes (the seek bar, the volume): at least 3:1 on the plain background in
  /// both themes and in every colour that can be picked, where [outline] was 1.5:1 and the bar read as no bar until it
  /// had filled (`test/wide_lists_test.dart`). The quiet-words colour, thinned as far as that allows.
  Color get track {
    for (var alpha = 0.5; alpha < 1; alpha += 0.05) {
      final mixed = Color.alphaBlend(textTertiary.withValues(alpha: alpha), base);
      if (_contrast(mixed, base) >= 3) return mixed;
    }
    return textTertiary;
  }

  /// A name that opens a page, on the colours of a cover: the deep shade of the accent in the light theme, where the
  /// accent itself is 2.8:1 on a peach cover. In the dark one the pale shade of it was near white and read as no link
  /// at all; this pink has as much colour as keeps 4.5:1 on every ground (`test/on_cover_test.dart`).
  Color get link => brightness == Brightness.light
      ? onPrimaryContainer
      : const Color(0xFFFFCFDD);

  /// This palette for what stands straight on the colours of a cover, as in the full player: the quiet words and
  /// icons are the text colour a little see-through instead of a grey. A grey was picked for a plain ground and fell to
  /// 1.4:1 to 3:1 on the colours of a cover; the text colour over a cover keeps what it has over any ground the cover
  /// can make (see `test/on_cover_test.dart`: words 4.5:1, icons 3:1).
  Palette get onCover {
    final pale = brightness == Brightness.light;
    return Palette._(
      brightness: brightness,
      base: base,
      washTop: washTop,
      washMid: washMid,
      surface: surface,
      surfaceRaised: surfaceRaised,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      text: text,
      textSecondary: text.withValues(alpha: pale ? 0.88 : 0.9),
      textTertiary: text.withValues(alpha: pale ? 0.68 : 0.72),
      outline: outline,
      outlineSoft: outlineSoft,
      error: error,
      success: success,
      menu: menu,
      dialog: dialog,
      sheet: sheet,
      snack: snack,
      onSnack: onSnack,
      accent: accent,
    );
  }

  static const light = Palette._(
    brightness: Brightness.light,
    base: Color(0xFFFFFFFF),
    washTop: Color(0xFFFFE3EC),
    washMid: Color(0xFFFFF3F7),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFF0F4),
    primary: Color(0xFFC4456B),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFFBE0E8),
    onPrimaryContainer: Color(0xFF7A1F3D),
    text: Color(0xFF22161A),
    textSecondary: Color(0xFF685359),
    textTertiary: Color(0xFF6E5B63),
    outline: Color(0xFFEBCFD8),
    outlineSoft: Color(0xFFF6E6EB),
    error: Color(0xFFB83A4B),
    success: Color(0xFF3F745C),
    menu: Color(0xFFFFF7F9),
    dialog: Color(0xFFFFF7F9),
    sheet: Color(0xFFFFF7F9),
    snack: Color(0xFF3A2A31),
    onSnack: Color(0xFFFFF3F7),
  );

  static const dark = Palette._(
    brightness: Brightness.dark,
    base: Color(0xFF0E0A0C),
    washTop: Color(0xFF3B1826),
    washMid: Color(0xFF1B0F15),
    surface: Color(0xFF1B1317),
    surfaceRaised: Color(0xFF261B21),
    primary: Color(0xFFF291AC),
    onPrimary: Color(0xFF3E0F20),
    primaryContainer: Color(0xFF4A2432),
    onPrimaryContainer: Color(0xFFFFD8E3),
    text: Color(0xFFF7EDF0),
    textSecondary: Color(0xFFBBA6AE),
    textTertiary: Color(0xFF8E7B83),
    outline: Color(0xFF4A3940),
    outlineSoft: Color(0xFF30242A),
    error: Color(0xFFFF8FA0),
    success: Color(0xFF8FCBAE),
    menu: Color(0xFF2B1F25),
    dialog: Color(0xFF241A1F),
    sheet: Color(0xFF211820),
    snack: Color(0xFFF7EDF0),
    onSnack: Color(0xFF22161A),
  );

  /// The palette for [brightness] in the colour [accent] the person picked; the pink one while it is null.
  ///
  /// Every tinted colour of the pink palette keeps its lightness and takes the hue of [accent], so the look is the
  /// same in any colour. What is read against a ground (the accent, the quiet words) is then darkened or lightened
  /// until it passes WCAG, whatever the colour picked.
  static Palette forAccent(Color? accent, Brightness brightness) {
    final pink = brightness == Brightness.light ? light : dark;
    if (accent == null || accent.toARGB32() == pinkAccent.toARGB32()) {
      return pink;
    }
    final seed = HSLColor.fromColor(accent);
    // How tinted the greys and washes are: a pale or grey pick tints less than the pink did
    final tint = (seed.saturation / pinkSaturation).clamp(0.0, 1.0);
    Color retint(Color c) {
      final hsl = HSLColor.fromColor(c);
      return hsl
          .withHue(seed.hue)
          .withSaturation((hsl.saturation * tint).clamp(0.0, 1.0))
          .toColor();
    }

    final base = retint(pink.base);
    final isLight = brightness == Brightness.light;
    final primaryContainer = retint(pink.primaryContainer);
    final Color primary;
    if (isLight) {
      primary = _readable(
        seed.withLightness(seed.lightness.clamp(0.2, 0.6)).toColor(),
        const Color(0xFFFFFFFF),
        4.5,
      );
    } else {
      primary = _readable(
        seed
            .withSaturation((seed.saturation * 1.5).clamp(0.0, 0.9))
            .withLightness(seed.lightness.clamp(0.75, 0.85))
            .toColor(),
        base,
        4.5,
      );
    }
    final onPrimary = isLight
        ? pink.onPrimary
        : _readable(retint(pink.onPrimary), primary, 4.5);
    final washTop = retint(pink.washTop);
    return Palette._(
      brightness: brightness,
      base: base,
      washTop: washTop,
      washMid: retint(pink.washMid),
      surface: retint(pink.surface),
      surfaceRaised: retint(pink.surfaceRaised),
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: _readable(
        retint(pink.onPrimaryContainer),
        primaryContainer,
        7,
      ),
      text: _readable(retint(pink.text), washTop, 12),
      textSecondary: _readable(retint(pink.textSecondary), washTop, 4.5),
      textTertiary: _readable(retint(pink.textTertiary), washTop, 4.5),
      outline: retint(pink.outline),
      outlineSoft: retint(pink.outlineSoft),
      error: pink.error,
      success: pink.success,
      menu: retint(pink.menu),
      dialog: retint(pink.dialog),
      sheet: retint(pink.sheet),
      snack: retint(pink.snack),
      onSnack: retint(pink.onSnack),
      accent: accent,
    );
  }

  /// The pink the app was designed in: the accent that gives back [light] and [dark] as they are.
  static const pinkAccent = Color(0xFFC4456B);

  /// Saturation of [pinkAccent] in HSL.
  static const pinkSaturation = 0.52;

  /// [color] with its lightness moved away from [ground] (darker on a light one, lighter on a dark one) until the
  /// two have the contrast [ratio].
  static Color _readable(Color color, Color ground, double ratio) {
    final darker = color.computeLuminance() < ground.computeLuminance();
    var hsl = HSLColor.fromColor(color);
    for (var i = 0; i < 100 && _contrast(hsl.toColor(), ground) < ratio; i++) {
      final next = hsl.lightness + (darker ? -0.01 : 0.01);
      if (next < 0 || next > 1) break;
      hsl = hsl.withLightness(next);
    }
    return hsl.toColor();
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (la > lb ? la + 0.05 : lb + 0.05) /
        (la > lb ? lb + 0.05 : la + 0.05);
  }
}
