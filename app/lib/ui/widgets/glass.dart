import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// A nearly opaque panel for the tab bar and the mini player, which float over scrolling content.
///
/// It used to blur what is behind it, like Apple's bars. Measured on the phone, those two blurs were all of what
/// kept the screen from keeping up with 120 Hz: drawing a frame took 8 ms with them against 3 ms without, whatever
/// the strength of the blur (6 or 28 alike), because a backdrop blur costs a full extra pass over the screen behind
/// it in every frame that moves. So the panel is plain, and dense enough (98.5%) that nothing behind it can be made out through text.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.border = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.glass.withValues(alpha: 0.985),
        borderRadius: borderRadius,
        border: border ? Border.all(color: p.outlineSoft) : null,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: child),
    );
  }
}
