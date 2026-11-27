import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/calm.dart';
import 'data/tv_mode.dart';
import 'strings.dart';
import 'theme/palette.dart';
import 'theme/theme.dart';
import 'ui/home_shell.dart';
import 'ui/scope.dart';
import 'ui/tv/tv.dart';
import 'ui/widgets/focus_nav.dart';
import 'ui/widgets/ambient_backdrop.dart';
import 'ui/widgets/motion.dart';
import 'ui/widgets/pip_host.dart';
import 'ui/widgets/settle_on_growth_physics.dart';
import 'ui/widgets/toast_layout.dart';

class SapocheApp extends StatefulWidget {
  const SapocheApp({super.key, required this.model});

  final AppModel model;

  @override
  State<SapocheApp> createState() => _SapocheAppState();
}

class _SapocheAppState extends State<SapocheApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The first screen is built before Flutter has resolved the locale, so the language is settled here too
    S.current = _languageFor(
      widget.model.settings.language,
      ui.PlatformDispatcher.instance.locale,
    );
    widget.model.room.setLanguage(S.current);
    widget.model.room.addListener(_syncTv);
    _syncTv();
  }

  bool _screenLogged = false;

  /// The device says whether it is a TV (once the first state is there), and the log learns how big its screen is: what a
  /// person with a box that draws wrong can send, and what the layout is chosen from.
  void _syncTv() {
    final room = widget.model.room;
    Tv.device = room.snapshot.television;
    if (_screenLogged || !room.ready) return;
    _screenLogged = true;
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    final px = view.physicalSize;
    final dpr = view.devicePixelRatio;
    room.note(
      '[screen] ${px.width.round()}x${px.height.round()} px, dpr '
      '${dpr.toStringAsFixed(2)}, ${(px.width / dpr).round()}x${(px.height / dpr).round()} dp, '
      'tv=${room.snapshot.television}, tvLayout=${Tv.on.value}',
    );
  }

  @override
  void dispose() {
    widget.model.room.removeListener(_syncTv);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

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
        listenable: Listenable.merge([model.settings, Calm.level]),
        builder: (context, _) {
          final chosen = model.settings.language;
          final effects = Calm.level.value;
          final instant =
              effects == EffectsLevel.minimal ||
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .accessibilityFeatures
                  .disableAnimations;
          return MaterialApp(
            title: S.appName,
            debugShowCheckedModeBanner: false,
            scrollBehavior: _ScrollBehavior(
              minimal: effects == EffectsLevel.minimal,
            ),
            themeMode: model.settings.themeMode,
            theme: buildTheme(
              Palette.forAccent(model.settings.accent, Brightness.light),
              effects: effects,
              instantTransitions: instant,
            ),
            darkTheme: buildTheme(
              Palette.forAccent(model.settings.accent, Brightness.dark),
              effects: effects,
              instantTransitions: instant,
            ),
            // Null: the phone decides (and a change in the phone's settings arrives here too)
            locale: chosen == null ? null : ui.Locale(chosen),
            supportedLocales: [for (final code in S.languages) ui.Locale(code)],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            localeResolutionCallback: (locale, supported) {
              final code = _languageFor(chosen, locale);
              _languageChanged(code);
              return ui.Locale(code);
            },
            // A dialog, a sheet or a page over the shell has the focus put on its first control while keys are in use
            navigatorObservers: [LandOnPush()],
            home: const _Root(),
            builder: (context, child) => PipHost(
              controller: model.room,
              // Over everything, dialogs and sheets too: the ring round what a remote has the focus on
              // The canvas of a TV is round the ring, so that the ring is as thick there as everywhere
              child: TvCanvas(
                child: FocusRingLayer(child: ToastLayout(child: child!)),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ScrollBehavior extends MaterialScrollBehavior {
  const _ScrollBehavior({this.minimal = false});

  final bool minimal;

  // A mouse (DeX, a computer) drags a row of covers the way a finger does
  @override
  Set<ui.PointerDeviceKind> get dragDevices => {
    ui.PointerDeviceKind.touch,
    ui.PointerDeviceKind.mouse,
    ui.PointerDeviceKind.stylus,
    ui.PointerDeviceKind.trackpad,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      SettleOnGrowthPhysics(parent: super.getScrollPhysics(context));

  // Minimal skips Android's stretch overscroll shader to save full-screen raster work on weak GPUs
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => minimal ? child : super.buildOverscrollIndicator(context, child, details);
}

/// Shows the home screen once the first state arrived, and paints the colours of the song that is playing behind it.
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
      child: AmbientBackdrop(
        child: ListenableBuilder(
          listenable: room,
          builder: (context, _) {
            final Widget page = room.ready
                ? const HomeShell(key: ValueKey('home'))
                : const SizedBox.expand(key: ValueKey('splash'));
            return AnimatedSwitcher(
              duration: Motion.of(context, 350),
              switchInCurve: Curves.easeOut,
              child: page,
            );
          },
        ),
      ),
    );
  }
}
