import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three bouncing bars that show which song is playing; they settle down when paused.
class Equalizer extends StatefulWidget {
  const Equalizer({
    super.key,
    required this.active,
    required this.color,
    this.size = 18,
  });

  final bool active;
  final Color color;
  final double size;

  @override
  State<Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<Equalizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(Equalizer old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.animateTo(0, duration: const Duration(milliseconds: 250));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _BarsPainter(_controller.value, widget.active, widget.color),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.t, this.active, this.color);

  final double t;
  final bool active;
  final Color color;

  static const _phases = [0.0, 0.33, 0.66];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final barWidth = size.width / 5;
    for (var i = 0; i < 3; i++) {
      final wave = active || t > 0
          ? (math.sin((t + _phases[i]) * 2 * math.pi) + 1) / 2
          : 0.0;
      final height = size.height * (0.25 + 0.75 * wave);
      final x = barWidth * (i * 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.t != t || old.color != color || old.active != active;
}
