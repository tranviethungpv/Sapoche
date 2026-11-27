import 'package:flutter/material.dart';

import '../home_shell.dart';

/// The top edge of a page that scrolls up under the status bar (on a tablet, a wide screen or a TV; a phone's page ends
/// below the status bar). Nothing is drawn there: the page goes up under the status bar as it is, with no strip of glass
/// and no small title coming in over it (that strip was taken out: it looked heavy).
///
/// The page itself pads its top by [topOf], so that it starts below the status bar and scrolls under it.
class ScrollEdge extends StatelessWidget {
  const ScrollEdge({super.key, required this.child});

  final Widget child;

  /// How far a page inside a [ScrollEdge] pads its top: by the status bar where it scrolls up under it (a tablet, a
  /// wide screen), and by nothing on a phone, where the edge has already put it below the status bar. Read from the
  /// page's own context, which is above the edge.
  static double topOf(BuildContext context) =>
      HomeShell.endsBelowStatusOf(context)
      ? 0
      : MediaQuery.paddingOf(context).top;

  @override
  Widget build(BuildContext context) {
    // On a phone the page simply ends below the status bar
    if (HomeShell.endsBelowStatusOf(context)) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: child,
        ),
      );
    }
    return child;
  }
}
