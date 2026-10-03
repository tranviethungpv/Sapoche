import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'palette.dart';

/// Palette and shapes for widgets that need more than Material's colour scheme offers.
@immutable
class SapocheTheme extends ThemeExtension<SapocheTheme> {
  const SapocheTheme(this.palette);

  final Palette palette;

  static const cardRadius = 14.0;
  static const artworkRadius = 10.0;

  /// Groups of rows and the larger see-through panels on a page.
  static const groupRadius = 22.0;

  @override
  SapocheTheme copyWith({Palette? palette}) =>
      SapocheTheme(palette ?? this.palette);

  @override
  SapocheTheme lerp(SapocheTheme? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension SapocheThemeContext on BuildContext {
  Palette get palette => Theme.of(this).extension<SapocheTheme>()!.palette;
}

const fontFamily = 'Inter';

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.primary,
    onPrimary: p.onPrimary,
    primaryContainer: p.primaryContainer,
    onPrimaryContainer: p.onPrimaryContainer,
    secondary: p.primary,
    onSecondary: p.onPrimary,
    secondaryContainer: p.primaryContainer,
    onSecondaryContainer: p.onPrimaryContainer,
    error: p.error,
    onError: p.base,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textSecondary,
    outline: p.outline,
    outlineVariant: p.outlineSoft,
    surfaceContainerHighest: p.surfaceRaised,
    surfaceContainerHigh: p.surfaceRaised,
    surfaceContainer: p.surfaceRaised,
    surfaceContainerLow: p.surface,
    surfaceContainerLowest: p.surface,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
  );

  // Large, tight, bold titles and calm body text in the style of Apple's apps
  final text = Typography.material2021().black
      .apply(fontFamily: fontFamily)
      .copyWith(
        displayLarge: _style(40, FontWeight.w800, -1.0, p.text),
        headlineLarge: _style(34, FontWeight.w800, -0.8, p.text),
        headlineMedium: _style(28, FontWeight.w700, -0.6, p.text),
        headlineSmall: _style(22, FontWeight.w700, -0.4, p.text),
        titleLarge: _style(20, FontWeight.w700, -0.3, p.text),
        titleMedium: _style(17, FontWeight.w600, -0.2, p.text),
        titleSmall: _style(15, FontWeight.w600, -0.1, p.text),
        bodyLarge: _style(17, FontWeight.w400, -0.2, p.text),
        bodyMedium: _style(15, FontWeight.w400, -0.1, p.text),
        bodySmall: _style(13, FontWeight.w400, 0, p.textSecondary),
        labelLarge: _style(16, FontWeight.w600, -0.1, p.text),
        labelMedium: _style(13, FontWeight.w600, 0, p.textSecondary),
        labelSmall: _style(11, FontWeight.w600, 0.2, p.textTertiary),
      );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    brightness: p.brightness,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: p.base,
    splashFactory: InkSparkle.splashFactory,
    // A mouse lights the row it is over, and a remote's or a keyboard's focus is clearly seen
    hoverColor: p.text.withValues(alpha: 0.06),
    focusColor: p.primary.withValues(alpha: 0.24),
    dividerColor: p.outlineSoft,
    extensions: [SapocheTheme(p)],
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.text,
      // The bar has no colour of its own, so Material would guess the icons from black: white ones on the pink veil
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: p.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: p.brightness,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: p.onPrimary,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: text.labelLarge,
        elevation: 0,
      ),
    ),
    // The quieter button: pink tint with pink text
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.primaryContainer,
        foregroundColor: p.onPrimaryContainer,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: text.labelLarge,
        elevation: 0,
        shadowColor: Colors.transparent,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.primary,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        side: BorderSide(color: p.outline),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        textStyle: text.labelLarge,
        shape: buttonShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.text),
    ),
    // Back is the same chevron everywhere, as on the round Back of an album page
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) =>
          const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF241A1F),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.textSecondary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF211820),
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.brightness == Brightness.light
          ? p.surfaceRaised
          : p.surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: text.bodyLarge?.copyWith(color: p.textTertiary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: p.primary, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.brightness == Brightness.light
          ? const Color(0xFF3A2A31)
          : const Color(0xFFF7EDF0),
      contentTextStyle: text.bodyMedium?.copyWith(
        color: p.brightness == Brightness.light
            ? const Color(0xFFFFF3F7)
            : const Color(0xFF22161A),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.primary,
      inactiveTrackColor: p.outline,
      thumbColor: p.primary,
      overlayColor: p.primary.withValues(alpha: 0.12),
      trackHeight: 4,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onPrimary : p.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.primary : p.outlineSoft,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.primary,
      linearTrackColor: p.outline,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: CupertinoPageTransitionsBuilder()},
    ),
  );
}

TextStyle _style(double size, FontWeight weight, double spacing, Color color) =>
    TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: spacing,
      color: color,
      height: 1.25,
    );
