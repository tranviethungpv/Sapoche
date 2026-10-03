import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// Placeholder rows shown while search results load: same shape as a track row, with a light
/// sweeping across them. One animation drives every row.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.rows = 8});

  final int rows;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = p.primaryContainer.withValues(
      alpha: p.brightness == Brightness.dark ? 0.55 : 0.75,
    );
    final light = p.primaryContainer.withValues(
      alpha: p.brightness == Brightness.dark ? 0.9 : 0.25,
    );
    return AnimatedBuilder(
      animation: _sweep,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          colors: [base, light, base],
          stops: const [0.25, 0.5, 0.75],
          begin: Alignment(-1.6 + _sweep.value * 3.2, -0.3),
          end: Alignment(-0.6 + _sweep.value * 3.2, 0.3),
        ).createShader(bounds),
        child: child,
      ),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        itemCount: widget.rows,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            children: [
              _block(54, 54, SapocheTheme.artworkRadius),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Slightly different widths so it does not look like a barcode
                    FractionallySizedBox(
                      widthFactor: 0.55 + 0.1 * (i % 3),
                      child: _block(16, double.infinity, 6),
                    ),
                    const SizedBox(height: 8),
                    FractionallySizedBox(
                      widthFactor: 0.3 + 0.08 * (i % 4),
                      child: _block(13, double.infinity, 6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _block(double height, double width, double radius) => Container(
    height: height,
    width: width,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}
