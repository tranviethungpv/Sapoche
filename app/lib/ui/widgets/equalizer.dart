import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'low_rate_timer.dart';

/// Three bouncing bars that show which song is playing; they settle down when paused. They move
/// about ten times a second rather than on every frame: same look, a fraction of the wake-ups.
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

class _EqualizerState extends State<Equalizer> {
  static const _tick = Duration(milliseconds: 100);
  static const _cycle = Duration(milliseconds: 1100);

  late final LowRateTimer _timer = LowRateTimer(_tick, () {
    setState(
      () => _t = (_t + _tick.inMilliseconds / _cycle.inMilliseconds) % 1,
    );
  });

  /// Where the bars are in their cycle, 0 to 1; 0 is at rest.
  double _t = 0;

  /// False when this screen is not the one showing (another tab, or behind the full player).
  bool _shown = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shown = TickerMode.valuesOf(context).enabled;
    _timer.run(widget.active && _shown);
  }

  @override
  void didUpdateWidget(Equalizer old) {
    super.didUpdateWidget(old);
    _timer.run(widget.active && _shown);
    if (!widget.active) _t = 0;
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _BarsPainter(_t, widget.active, widget.color),
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
