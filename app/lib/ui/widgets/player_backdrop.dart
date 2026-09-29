import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../cover_color.dart';
import 'wash.dart';

/// Background of the full player: the cover's colour as soft blobs, under the same pink veil as the
/// rest of the app. The colour changes smoothly from song to song. The blobs stand still: drifting
/// them meant redrawing the whole screen on every frame for as long as the player was open.
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({super.key, required this.coverUrl});

  final String? coverUrl;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop> {
  Color? _cover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.coverUrl != old.coverUrl) _load();
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
            child: CustomPaint(
              painter: _BlobPainter(color ?? target, dark ? 0.6 : 0.42),
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
  _BlobPainter(this.color, this.strength);

  final Color color;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    // Three blobs: centre as a share of the screen, radius as a share of its width, and strength
    const blobs = [
      (Offset(0.25, 0.22), 0.85, 1.0),
      (Offset(0.80, 0.55), 0.75, 0.8),
      (Offset(0.40, 0.92), 0.9, 0.7),
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
      old.color != color || old.strength != strength;
}
