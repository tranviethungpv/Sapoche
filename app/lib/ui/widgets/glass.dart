import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import '../../theme/theme.dart';

/// The look of Apple's Liquid Glass, drawn cheaply: a pane whose fill is lighter at the top, a bright edge that
/// fades towards the opposite corner, and a soft shadow when the pane floats.
///
/// There is no blur of what is behind and no lens: measured on a phone, a backdrop blur costs a full extra pass over
/// the screen in every frame that moves, enough to lose 120 Hz. Over the pink wash, which is smooth, the pane still
/// reads as glass; over a list that scrolls beneath it ([dense]) the fill is nearly opaque so no text shows through.
class GlassDecoration extends Decoration {
  const GlassDecoration({
    required this.palette,
    this.radius = const BorderRadius.all(Radius.circular(24)),
    this.tint,
    this.dense = false,
    this.floating = false,
    this.rim = true,
    this.solid = false,
  });

  /// The usual panes: [radius] in points; a number as big as the pane is a capsule or a circle.
  factory GlassDecoration.of(
    Palette palette, {
    double radius = 24,
    Color? tint,
    bool dense = false,
    bool floating = false,
    bool rim = true,
    bool solid = false,
  }) => GlassDecoration(
    palette: palette,
    radius: BorderRadius.circular(radius),
    tint: tint,
    dense: dense,
    floating: floating,
    rim: rim,
    solid: solid,
  );

  final Palette palette;
  final BorderRadius radius;

  /// Colours the glass, e.g. the pink of something chosen.
  final Color? tint;

  /// Nearly opaque, for panes laid over things that move.
  final bool dense;

  /// Casts a shadow.
  final bool floating;

  final bool rim;

  /// Fully coloured by [tint], like a pane of coloured glass: for the button that matters most.
  final bool solid;

  bool get _dark => palette.brightness == Brightness.dark;

  @override
  EdgeInsetsGeometry get padding => EdgeInsets.zero;

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) =>
      Path()..addRRect(radius.toRRect(rect));

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      radius.toRRect(Offset.zero & size).contains(position);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _GlassPainter(this);

  @override
  bool operator ==(Object other) =>
      other is GlassDecoration &&
      other.palette == palette &&
      other.radius == radius &&
      other.tint == tint &&
      other.dense == dense &&
      other.floating == floating &&
      other.rim == rim &&
      other.solid == solid;

  @override
  int get hashCode =>
      Object.hash(palette, radius, tint, dense, floating, rim, solid);
}

class _GlassPainter extends BoxPainter {
  _GlassPainter(this.d);

  final GlassDecoration d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final rrect = d.radius.toRRect(rect);
    final dark = d._dark;
    final p = d.palette;

    if (d.floating) {
      // A soft shadow beneath: the pane is above what it floats over
      final shadow = Paint()
        ..color = dark
            ? const Color(0x66000000)
            : p.primary.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawRRect(rrect.shift(const Offset(0, 6)), shadow);
    }

    // The body: lighter on top, as if the light came from above
    final body =
        d.tint ?? (dark ? const Color(0xFFFFFFFF) : const Color(0xFFFFFFFF));
    final double top;
    final double bottom;
    if (dark) {
      top = d.dense ? 0.0 : (d.tint == null ? 0.13 : 0.55);
      bottom = d.dense ? 0.0 : (d.tint == null ? 0.06 : 0.40);
    } else {
      top = d.dense ? 0.985 : (d.tint == null ? 0.72 : 0.78);
      bottom = d.dense ? 0.96 : (d.tint == null ? 0.46 : 0.56);
    }
    if (d.solid) {
      final colour = d.tint ?? p.primary;
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colour.withValues(alpha: 0.98),
              colour.withValues(alpha: 0.88),
            ],
          ).createShader(rect),
      );
    } else if (dark && d.dense) {
      // A dense dark pane is its own colour, not white
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              (d.tint ?? Colors.white).withValues(
                alpha: d.tint == null ? 0.10 : 0.4,
              ),
              const Color(0xFF2A2026),
            ).withValues(alpha: 0.95),
            const Color(0xFF1F171C).withValues(alpha: 0.94),
          ],
        ).createShader(rect);
      canvas.drawRRect(rrect, paint);
    } else {
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            body.withValues(alpha: top),
            body.withValues(alpha: bottom),
          ],
        ).createShader(rect);
      canvas.drawRRect(rrect, paint);
    }

    // The sheen: a bright wash across the upper part, which is what makes it look like a curved pane
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, 0.5],
        colors: [
          Colors.white.withValues(alpha: dark ? 0.12 : 0.40),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, sheen);

    if (!d.rim) return;
    // The edge: bright where the light hits (top left), fading, with a faint return at the bottom right
    final stroke = rrect.deflate(0.6);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        stops: const [0, 0.42, 0.7, 1],
        colors: dark
            ? [
                Colors.white.withValues(alpha: 0.55),
                Colors.white.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0.04),
                Colors.white.withValues(alpha: 0.26),
              ]
            : [
                Colors.white.withValues(alpha: 1),
                Colors.white.withValues(alpha: 0.55),
                p.primary.withValues(alpha: 0.10),
                p.primary.withValues(alpha: 0.26),
              ],
      ).createShader(rect);
    canvas.drawRRect(stroke, edge);
  }
}

/// A pane of glass around [child]. For bars that float over the screen, [dense] and [floating].
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.border = false,
    this.dense = true,
    this.floating = false,
    this.tint,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Kept for the callers that asked for an edge; the edge is part of the glass now.
  final bool border;
  final bool dense;
  final bool floating;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: GlassDecoration(
        palette: context.palette,
        radius: borderRadius,
        dense: dense,
        floating: floating,
        tint: tint,
        rim: border || borderRadius != BorderRadius.zero,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: child),
    );
  }
}

/// A round button of glass for the top of a page: back, settings.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    this.icon,
    this.child,
    required this.onPressed,
    this.tooltip,
    this.size = 40,
  }) : assert(icon != null || child != null);

  final IconData? icon;

  /// Instead of [icon], for a picture that carries something, such as a dot.
  final Widget? child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final button = Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: math.max(size, 44),
          height: math.max(size, 44),
          child: Center(
            child: DecoratedBox(
              decoration: GlassDecoration.of(p, radius: size, floating: true),
              child: SizedBox(
                width: size,
                height: size,
                child: child ?? Icon(icon, size: size * 0.5, color: p.text),
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// The way back at the top of a page, in glass. It is the platform's own back button inside the pane, so it
/// goes back the way the platform does and reads as a back button to a screen reader.
class GlassBackButton extends StatelessWidget {
  const GlassBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: DecoratedBox(
        decoration: GlassDecoration.of(p, radius: 40, floating: true),
        child: SizedBox.square(
          dimension: 40,
          child: BackButton(
            color: p.text,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(40),
              padding: EdgeInsets.zero,
              iconSize: 20,
            ),
          ),
        ),
      ),
    );
  }
}
