import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// A translucent panel that blurs whatever scrolls behind it, like Apple's bars.
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
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.glass,
            borderRadius: borderRadius,
            border: border ? Border.all(color: p.outlineSoft) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
