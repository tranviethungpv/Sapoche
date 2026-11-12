import 'package:flutter/material.dart';

/// Fades what [child] draws out at its top and its bottom edge, so that a list that goes on under something is not cut
/// off with a line. It lets what is behind show through, which a veil of the page's colour cannot: the player's page is
/// tinted by the cover, and a veil of the plain background shows on it as a pale band.
///
/// A mask is one more layer drawn while the list moves; use it where a list sits on a page that does not scroll.
class EdgeFade extends StatelessWidget {
  const EdgeFade({super.key, this.top = 0, this.bottom = 0, required this.child});

  /// How far in from each edge the fade goes, in dp; 0 for no fade there.
  final double top;
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) {
      final h = rect.height;
      if (h <= 0) return const LinearGradient(colors: [Colors.white, Colors.white]).createShader(rect);
      final a = (top / h).clamp(0.0, 0.5);
      final b = (1 - bottom / h).clamp(0.5, 1.0);
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          if (top > 0) Colors.transparent,
          Colors.white,
          Colors.white,
          if (bottom > 0) Colors.transparent,
        ],
        stops: [
          if (top > 0) 0,
          if (top > 0) a else 0,
          if (bottom > 0) b else 1,
          if (bottom > 0) 1,
        ],
      ).createShader(rect);
    },
    child: child,
  );
}
