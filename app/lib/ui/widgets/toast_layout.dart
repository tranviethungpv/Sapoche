import 'package:flutter/material.dart';

import '../home_shell.dart';
import 'mini_player.dart';
import 'player_bar.dart';

/// Sets where a toast (a snack bar) floats. On a phone it spans the width, as Material has it. In a window wide enough
/// for [maxWidth] it keeps to that, in the middle, instead of running across a screen of 1600 dp, and on a tablet or a
/// computer it floats above the player, which lies along the bottom there and which the toast would hide.
class ToastLayout extends StatelessWidget {
  const ToastLayout({super.key, required this.child});

  final Widget child;

  /// Wide enough for a sentence and a button, and for little more.
  static const maxWidth = 420.0;

  /// Material's own margin around a floating toast.
  static const _side = 15.0;
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width - 2 * _side > maxWidth;
    final layout = HomeShell.layoutOf(context);
    if (!wide && layout == ShellLayout.bars) return child;
    // The scaffold lifts a toast over its own bottom bar, which the phone layout has; the others draw the player
    // inside the page, so the toast clears it by its height and by the space under it
    final lift = switch (layout) {
      ShellLayout.bars => 0.0,
      ShellLayout.rail =>
        16 +
            MiniPlayer.heightOf(context) +
            MediaQuery.viewPaddingOf(context).bottom,
      ShellLayout.sidebar =>
        12 + PlayerBar.height + MediaQuery.viewPaddingOf(context).bottom,
    };
    return Theme(
      data: theme.copyWith(
        snackBarTheme: theme.snackBarTheme.copyWith(
          width: wide ? maxWidth : null,
          insetPadding: EdgeInsets.fromLTRB(_side, 5, _side, _gap + lift),
        ),
      ),
      child: child,
    );
  }
}
