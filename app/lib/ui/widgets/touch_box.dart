import 'package:flutter/material.dart';

/// The least a finger needs (Android's guideline, and a little over Apple's 44).
const double touchSize = 48;

/// The height of the place of a bar (the seek bar, the volume) that is dragged along: a finger's [touchSize], but the
/// [short] one it had on a window lower than 500, a phone on its side, where the controls are fitted into what height
/// there is and 20 more is what does not fit.
double barTouchHeight(BuildContext context, double short) =>
    MediaQuery.sizeOf(context).height < 500 ? short : touchSize;

/// [child] drawn as it is, in a place that is at least [touchSize] square and answers a touch anywhere in it: for a
/// control that looks smaller than a finger (a bare glyph, a pill) and should not be harder to hit for that.
class TouchBox extends StatelessWidget {
  const TouchBox({
    super.key,
    required this.onTap,
    required this.child,
    this.semantic = true,
  });

  final VoidCallback? onTap;
  final Widget child;

  /// False when [child] is a control with its own semantics (a button): the place round it is then not a second one.
  final bool semantic;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minWidth: touchSize,
      minHeight: touchSize,
    ),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: !semantic,
      onTap: onTap,
      // As big as the child, and no bigger than that unless the minimum asks it: it must not take the width it is offered
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    ),
  );
}
