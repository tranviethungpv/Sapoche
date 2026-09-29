import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'strings.dart';
import 'theme/palette.dart';
import 'theme/theme.dart';
import 'ui/home_shell.dart';
import 'ui/scope.dart';
import 'ui/welcome_page.dart';
import 'ui/widgets/wash.dart';

class UnisonApp extends StatelessWidget {
  const UnisonApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      model: model,
      child: ListenableBuilder(
        listenable: model.settings,
        builder: (context, _) => MaterialApp(
          title: S.appName,
          debugShowCheckedModeBanner: false,
          themeMode: model.settings.themeMode,
          theme: buildTheme(Palette.light),
          darkTheme: buildTheme(Palette.dark),
          home: const _Root(),
        ),
      ),
    );
  }
}

/// Chooses between the welcome screen and the room, and paints the pink veil behind both.
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
            final Widget page;
            if (!room.ready) {
              page = const SizedBox.expand(key: ValueKey('splash'));
            } else if (!room.snapshot.inRoom) {
              page = const WelcomePage(key: ValueKey('welcome'));
            } else {
              page = const HomeShell(key: ValueKey('home'));
            }
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
