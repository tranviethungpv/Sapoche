import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The app's backdrop: white (or black) with a pale pink veil laid over the top of it.
class PinkWash extends StatelessWidget {
  const PinkWash({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// 0 hides the veil, 1 is the normal strength.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: p.base,
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
