import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../format.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../player/look.dart';
import 'focus_nav.dart';
import 'low_rate_timer.dart';
import 'touch_box.dart';
import 'motion.dart';

/// Seek bar with elapsed and remaining time. It moves five times a second while playing, which is
/// finer than a pixel of the bar, and it grows under the finger like Apple's.
class PlaybackBar extends StatefulWidget {
  const PlaybackBar({
    super.key,
    required this.controller,
    this.compact = false,
    this.inline = false,
    this.middle,
  });

  final RoomController controller;

  /// One low line with the times on either side, for the player bar of a wide screen.
  final bool compact;

  /// One line with the times on either side like [compact], but with the bar of the player's look (its thumb) and 26 high,
  /// for the small player of a phone on its side.
  final bool inline;

  /// Between the two times, in the line under the bar (the quality of the sound).
  final Widget? middle;

  @override
  State<PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<PlaybackBar> {
  late final LowRateTimer _ticker = LowRateTimer(
    const Duration(milliseconds: 200),
    () => setState(() {}),
  );
  double? _dragFraction;

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.player.addListener(_syncTicker);
    _c.addListener(_syncTicker);
    _syncTicker();
  }

  void _syncTicker() {
    _ticker.run(_c.player.value.playing);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.player.removeListener(_syncTicker);
    _c.removeListener(_syncTicker);
    _ticker.dispose();
    super.dispose();
  }

  double _fractionAt(double dx, double width) => (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final duration = _c.durationMs();
    final dragging = _dragFraction != null;
    final fraction =
        _dragFraction ??
        (duration > 0 ? (_c.positionMs() / duration).clamp(0.0, 1.0) : 0.0);
    final shownMs = (fraction * duration).round();

    final inline = widget.inline;
    final compact = widget.compact || inline;
    // A thin line with a round thumb, where the look of the player asks for it (not in the compact bar of a wide window)
    final thin = (!compact || inline) && PlayerLookScope.of(context).thinBar;
    // A screen reader reads it as a slider and moves it ten seconds at a time
    int step(int by) => (shownMs + by).clamp(0, duration);
    final bar = LayoutBuilder(
      builder: (context, box) => Semantics(
        slider: true,
        label: S.songPosition,
        value: formatDuration(shownMs),
        increasedValue: formatDuration(step(10000)),
        decreasedValue: formatDuration(step(-10000)),
        onIncrease: duration > 0 ? () => _c.seek(step(10000)) : null,
        onDecrease: duration > 0 ? () => _c.seek(step(-10000)) : null,
        // The left and right keys of a remote move it too
        child: KeySlider(
          onStep: (way) {
            if (duration > 0) _c.seek(step(way * 10000));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => setState(
              () =>
                  _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth),
            ),
            onHorizontalDragUpdate: (d) => setState(
              () =>
                  _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth),
            ),
            onHorizontalDragEnd: (_) => _finish(duration),
            onHorizontalDragCancel: () => setState(() => _dragFraction = null),
            onTapUp: (d) {
              _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth);
              _finish(duration);
            },
            child: SizedBox(
              // The line is 4 to 10 high; the place that answers a touch and a drag is the full 48. Not in the bar of a
              // wide window (`compact`), which is a fixed height with the buttons above it: 20, as it was, nor on a
              // phone on its side
              height: inline
                  ? 26
                  : (compact ? 20 : barTouchHeight(context, 28)),
              child: Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(
                    end: (compact && !inline) || thin
                        ? (dragging ? 6 : 4)
                        : (dragging ? 10 : 5),
                  ),
                  duration: Motion.of(context, 160),
                  curve: Curves.easeOut,
                  builder: (context, height, _) => thin
                      ? _thinLine(p, height, fraction, box.maxWidth, dragging)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(height),
                          child: Stack(
                            children: [
                              Container(height: height, color: p.track),
                              FractionallySizedBox(
                                widthFactor: fraction,
                                child: Container(
                                  height: height,
                                  color: dragging
                                      ? p.primary
                                      : p.primary.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final elapsed = Text(formatDuration(shownMs), style: _timeStyle(context));
    final left = Text(
      '−${formatDuration(duration - shownMs)}',
      style: _timeStyle(context),
    );
    if (compact) {
      return Row(
        children: [
          elapsed,
          SizedBox(width: inline ? 8 : 10),
          Expanded(child: bar),
          SizedBox(width: inline ? 8 : 10),
          left,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        bar,
        // Up under the line, as close as when the place round it was 28 high
        Transform.translate(
          offset: Offset(0, -(barTouchHeight(context, 28) - 28) / 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              elapsed,
              if (widget.middle != null)
                Expanded(child: Center(child: widget.middle)),
              left,
            ],
          ),
        ),
      ],
    );
  }

  /// The line of the thin bar: the text colour filling a quiet track, and a round thumb at its end.
  Widget _thinLine(
    Palette p,
    double height,
    double fraction,
    double width,
    bool dragging,
  ) {
    final thumb = dragging ? 16.0 : 12.0;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: Stack(
            children: [
              Container(height: height, color: p.track),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(height: height, color: p.text),
              ),
            ],
          ),
        ),
        Positioned(
          left: fraction * width - thumb / 2,
          child: Container(
            width: thumb,
            height: thumb,
            decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
          ),
        ),
      ],
    );
  }

  TextStyle? _timeStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: context.palette.textSecondary,
      );

  void _finish(int duration) {
    final fraction = _dragFraction;
    setState(() => _dragFraction = null);
    if (fraction != null && duration > 0) {
      _c.seek((fraction * duration).round());
    }
  }
}
