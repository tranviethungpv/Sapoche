import 'package:flutter/material.dart';

/// How far from the left edge of the window the pages of a tab begin: the width of the rail or the sidebar, which the
/// pages are drawn beside. A page with a backdrop of its own (an album's) paints it across the whole window, so that
/// the glass of the sidebar blurs its colours, and keeps its content clear of this inset.
class SideInset extends InheritedWidget {
  const SideInset({super.key, required this.left, required super.child});

  final double left;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SideInset>()?.left ?? 0;

  @override
  bool updateShouldNotify(SideInset old) => left != old.left;
}

/// Keeps the first page of a tab to a readable width in a big window, in the middle of what the sidebar leaves, so that
/// a list of songs is not stretched across a screen of 1600 dp. The backdrop behind it still fills the window.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});

  final Widget child;

  static const max = 1180.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: SideInset.of(context)),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: max),
        child: child,
      ),
    ),
  );
}
