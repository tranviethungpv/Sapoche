import 'package:flutter/material.dart';

import '../../data/home_model.dart';
import '../../strings.dart';
import '../cover_glow.dart';
import 'artwork.dart';

/// The cover of a mix made for the person, drawn on the phone: the cover of the song they play most in it, under a veil
/// of the colour that cover is, with "Mix 1" and who is in it in the same place on every mix. The picture is what makes
/// one mix look unlike the next; with no picture (offline, not yet loaded) the veil alone is the cover, in a colour of
/// its own for each mix.
///
/// The words are white on that veil, which [CoverGlow.deepen] keeps dark enough to read them on at 4.5:1.
class MixCover extends StatefulWidget {
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
  State<MixCover> createState() => _MixCoverState();
}

class _MixCoverState extends State<MixCover> {
  late Future<Color?> _tone = _toneOf();

  String? get _picture => widget.mix.covers.firstOrNull;

  Future<Color?> _toneOf() {
    final picture = _picture;
    return picture == null ? Future.value(null) : CoverGlow.tone(picture);
  }

  @override
  void didUpdateWidget(MixCover old) {
    super.didUpdateWidget(old);
    if (old.mix.covers.firstOrNull != _picture) _tone = _toneOf();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final radius = size * 0.14;
    // Under 100 points there is room for the number alone; the artists are beside the cover then
    final tiny = size < 100;
    final names = !tiny && widget.artists;
    final small = size < 150;
    final theme = Theme.of(context).textTheme;
    final fallback = CoverGlow.toneFor(widget.mix.number);
    return FutureBuilder<Color?>(
      future: _tone,
      builder: (context, async) {
        final tone = async.data ?? fallback;
        final picture = _picture;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: tone),
                if (picture != null)
                  Artwork(
                    url: barlessThumbnail(picture),
                    size: size,
                    radius: 0,
                    wide: true,
                  ),
                // The veil: light at the top, where the picture shows, deep under the words
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        tone.withValues(alpha: 0.35),
                        tone.withValues(alpha: 0.82),
                        tone.withValues(alpha: 0.95),
                      ],
                      stops: const [0, 0.5, 1],
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
                        S.dailyMix(widget.mix.number),
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
                          widget.mix.artists.take(3).join(' · '),
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
      },
    );
  }
}
