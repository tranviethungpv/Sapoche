import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../cover_color.dart';
import 'wash.dart';

/// Background of the full player: the cover's colour drifting slowly as soft blobs, under the same
/// pink veil as the rest of the app. The colour changes smoothly from song to song, and the drift
/// stops while nothing plays.
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({
    super.key,
    required this.coverUrl,
    required this.playing,
  });

  final String? coverUrl;
  final bool playing;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  Color? _cover;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.playing) _drift.repeat();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.coverUrl != old.coverUrl) _load();
    if (widget.playing && !_drift.isAnimating) {
      _drift.repeat();
    } else if (!widget.playing && _drift.isAnimating) {
      _drift.stop();
    }
  }

  void _load() {
    final url = widget.coverUrl;
    if (url == null) {
      setState(() => _cover = null);
      return;
    }
    CoverColor.of(url).then((color) {
      if (mounted && widget.coverUrl == url) setState(() => _cover = color);
    });
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = p.brightness == Brightness.dark;
    // A song without a usable colour falls back to the app's own pink
    // Pulled towards the app's rose so a beige or green cover still reads as a pink veil, not mud
    final target = _cover == null
        ? p.primary
        : Color.lerp(_cover, p.primary, 0.45)!;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: p.base),
        TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: target),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          builder: (context, color, _) => RepaintBoundary(
            child: AnimatedBuilder(
              animation: _drift,
              builder: (context, _) => CustomPaint(
                painter: _BlobPainter(
                  color ?? target,
                  _drift.value,
                  dark ? 0.6 : 0.42,
                ),
              ),
            ),
          ),
        ),
        const PinkWash(
          intensity: 0.55,
          opaque: false,
          child: SizedBox.expand(),
        ),
      ],
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.color, this.t, this.strength);

  final Color color;
  final double t;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final angle = t * 2 * math.pi;
    // Three blobs on slow, different orbits
    final blobs = [
      (
        Offset(0.25 + 0.12 * math.sin(angle), 0.22 + 0.08 * math.cos(angle)),
        0.85,
        1.0,
      ),
      (
        Offset(
          0.80 + 0.10 * math.cos(angle * 2),
          0.55 + 0.10 * math.sin(angle),
        ),
        0.75,
        0.8,
      ),
      (
        Offset(
          0.40 + 0.15 * math.sin(angle + 2),
          0.92 + 0.05 * math.cos(angle * 2),
        ),
        0.9,
        0.7,
      ),
    ];
    for (final (center, radius, weight) in blobs) {
      final at = Offset(center.dx * size.width, center.dy * size.height);
      final r = radius * size.width;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: strength * weight),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: at, radius: r));
      canvas.drawCircle(at, r, paint);
    }
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.color != color || old.t != t || old.strength != strength;
}
