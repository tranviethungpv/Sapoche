import 'package:flutter/material.dart';

import '../../data/home_model.dart';
import '../../strings.dart';
import '../cover_glow.dart';

/// The cover of a mix made for the person, drawn on the phone and from nothing but its number: a colour of its own for
/// each mix, deepest in the corner where "Mix 1" is, rings like the grooves of a record and the number itself, large and
/// faint. It has no picture on purpose: a picture of a song under a veil read as a cover that had not loaded, and
/// brought the lettering of that song's cover with it.
///
/// The words are white on the deep corner, which [CoverGlow.deepen] keeps dark enough to read them on at 4.5:1.
class MixCover extends StatelessWidget {
  const MixCover({
    super.key,
    required this.mix,
    required this.size,
    this.artists = true,
  });

  final DailyMix mix;
  final double size;

  /// The artists under the number, when the cover is big enough and nothing is drawn over it or beside it that says them.
  final bool artists;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.14;
    // Under 100 points there is room for the number alone; the artists are beside the cover then
    final tiny = size < 100;
    final names = !tiny && artists;
    final small = size < 150;
    final theme = Theme.of(context).textTheme;
    final tone = CoverGlow.toneFor(mix.number);
    final light = HSLColor.fromColor(tone).withLightness(0.42).toColor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [light, tone],
                  stops: const [0, 0.85],
                ),
              ),
            ),
            CustomPaint(painter: _Rings(size)),
            Positioned(
              right: size * 0.06,
              top: -size * 0.12,
              child: Text(
                '${mix.number}',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: size * 0.95,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.16),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(
                tiny
                    ? 8
                    : small
                    ? 10
                    : 14,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.dailyMix(mix.number),
                    maxLines: 1,
                    style:
                        (tiny
                                ? theme.titleMedium
                                : small
                                ? theme.titleLarge
                                : theme.headlineSmall)
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              height: 1,
                            ),
                  ),
                  if (names) const SizedBox(height: 4),
                  if (names)
                    Text(
                      mix.artists.take(3).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: small ? 10 : 12,
                        height: 1.2,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three rings round a point near the top right, thin and faint.
class _Rings extends CustomPainter {
  const _Rings(this.size);

  final double size;

  @override
  void paint(Canvas canvas, Size _) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.012
      ..color = Colors.white.withValues(alpha: 0.12);
    for (final f in const [0.35, 0.55, 0.75]) {
      canvas.drawCircle(Offset(size * 0.78, size * 0.3), size * f, paint);
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.size != size;
}
