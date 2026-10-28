import 'package:flutter/material.dart';

/// How far from the left edge of the window the pages of a tab begin: the width of the rail or the sidebar, which the
/// pages are drawn beside, and the notch or the system's bar at that side. A page with a backdrop of its own (an
/// album's) paints it across the whole window, under the sidebar's glass and under the notch, and keeps its content
/// clear of this inset. [right] is the same for the other side, where there is only a notch or a bar.
class SideInset extends InheritedWidget {
  const SideInset({
    super.key,
    required this.left,
    this.right = 0,
    required super.child,
  });

  final double left;
  final double right;

  static SideInset? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SideInset>();

  static double of(BuildContext context) => _of(context)?.left ?? 0;

  /// What a page pads itself by at the two sides, to leave the rail and the notch clear.
  static EdgeInsets paddingOf(BuildContext context) {
    final inset = _of(context);
    return EdgeInsets.only(left: inset?.left ?? 0, right: inset?.right ?? 0);
  }

  @override
  bool updateShouldNotify(SideInset old) =>
      left != old.left || right != old.right;
}

/// Keeps the first page of a tab to a readable width in a big window, in the middle of what the sidebar leaves, so that
/// a list of songs is not stretched across a screen of 1600 dp. The backdrop behind it still fills the window.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});

  final Widget child;

  static const max = 1180.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: SideInset.paddingOf(context),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: max),
        child: child,
      ),
    ),
  );
}

/// A page this wide (a browser, a tablet on its side, a television) shows the cover and what is said of a list of songs beside the list, as Apple Music's web page
/// does, instead of a column in the middle with the sides empty. The two halves stay together in the middle of a window
/// wider than [splitMax].
const splitWidth = 880.0;
const splitMax = 1500.0;

/// The side of the cover, and the space between it and the list, in that layout.
const splitCover = 320.0;
const splitGap = 40.0;

/// How a page with a cover and a list of songs is laid out beside each other: the cover and what is said of it on the
/// left, the list on the right. A window [splitWidth] wide has it at full size; a phone on its side has it too, with the
/// left half narrower and the cover small by the height it has, so that the title and Play still show above the mini
/// player that floats over the foot of it. Null where the page is a single column.
class SplitLayout {
  const SplitLayout._({
    required this.left,
    required this.cover,
    required this.gap,
    required this.pad,
    this.phone = false,
  });

  /// Width of the left half, side of the cover in it, space between the halves and at the sides of the pair.
  final double left;
  final double cover;
  final double gap;
  final double pad;

  /// A phone on its side, where the title is set smaller too: the mini player floats over the foot of the left half.
  final bool phone;

  static SplitLayout? of(BoxConstraints box) {
    if (box.maxWidth >= splitWidth) {
      return const SplitLayout._(
        left: splitCover,
        cover: splitCover,
        gap: splitGap,
        pad: 32,
      );
    }
    if (box.maxWidth > box.maxHeight && box.maxWidth >= 560) {
      return SplitLayout._(
        left: 300,
        cover: (box.maxHeight * 0.25).clamp(88.0, 140.0),
        gap: 20,
        pad: 20,
        phone: true,
      );
    }
    return null;
  }
}
