import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The app's backdrop: white (or black) with a pale pink veil laid over the top of it.
class PinkWash extends StatelessWidget {
  const PinkWash({
    super.key,
    required this.child,
    this.intensity = 1,
    this.opaque = true,
  });

  final Widget child;

  /// 0 hides the veil, 1 is the normal strength.
  final double intensity;

  /// Paints the plain white or black under the veil. Turn off to lay the veil over something else.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: opaque ? p.base : Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.38, 1],
            colors: [
              p.washTop.withValues(alpha: intensity),
              p.washMid.withValues(alpha: 0.7 * intensity),
              p.base.withValues(alpha: 0),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}
