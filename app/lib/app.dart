import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'strings.dart';
import 'theme/palette.dart';
import 'theme/theme.dart';
import 'ui/home_shell.dart';
import 'ui/scope.dart';
import 'ui/widgets/wash.dart';

class UnisonApp extends StatefulWidget {
  const UnisonApp({super.key, required this.model});

  final AppModel model;

  @override
  State<UnisonApp> createState() => _UnisonAppState();
}

class _UnisonAppState extends State<UnisonApp> {
  @override
  void initState() {
    super.initState();
    // The first screen is built before Flutter has resolved the locale, so the language is settled here too
    S.current = _languageFor(
      widget.model.settings.language,
      ui.PlatformDispatcher.instance.locale,
    );
    widget.model.room.setLanguage(S.current);
  }

  /// The person's choice, or else the phone's language when the app has it, or English.
  static String _languageFor(String? chosen, ui.Locale? phone) {
    if (chosen != null && S.languages.contains(chosen)) return chosen;
    return S.languages.contains(phone?.languageCode)
        ? phone!.languageCode
        : 'en';
  }

  /// Texts are read from [S] while the screens are built, so a screen that is already there does not know
  /// the language changed: every element is built again, once, after the frame.
  void _languageChanged(String code) {
    if (S.current == code) return;
    S.current = code;
    widget.model.room.setLanguage(code);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return AppScope(
      model: model,
      child: ListenableBuilder(
        listenable: model.settings,
        builder: (context, _) {
          final chosen = model.settings.language;
          return MaterialApp(
            title: S.appName,
            debugShowCheckedModeBanner: false,
            themeMode: model.settings.themeMode,
            theme: buildTheme(Palette.light),
            darkTheme: buildTheme(Palette.dark),
            // Null: the phone decides (and a change in the phone's settings arrives here too)
            locale: chosen == null ? null : ui.Locale(chosen),
            supportedLocales: [for (final code in S.languages) ui.Locale(code)],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            localeResolutionCallback: (locale, supported) {
              final code = _languageFor(chosen, locale);
              _languageChanged(code);
              return ui.Locale(code);
            },
            home: const _Root(),
          );
        },
      ),
    );
  }
}

/// Shows the home screen once the first state arrived, and paints the pink veil behind it.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: PinkWash(
        child: ListenableBuilder(
          listenable: room,
          builder: (context, _) {
            final Widget page = room.ready
                ? const HomeShell(key: ValueKey('home'))
                : const SizedBox.expand(key: ValueKey('splash'));
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOut,
              child: page,
            );
          },
        ),
      ),
    );
  }
}
