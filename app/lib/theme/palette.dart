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
    textSecondary: Color(0xFF75606A),
    textTertiary: Color(0xFF8F7B84),
    outline: Color(0xFFEBCFD8),
    outlineSoft: Color(0xFFF6E6EB),
    error: Color(0xFFB83A4B),
    success: Color(0xFF4E8F72),
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
  );
}
