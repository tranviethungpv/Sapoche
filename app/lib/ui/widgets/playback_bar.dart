import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../format.dart';
import '../../theme/theme.dart';
import 'low_rate_timer.dart';

/// Seek bar with elapsed and remaining time. It moves five times a second while playing, which is
/// finer than a pixel of the bar, and it grows under the finger like Apple's.
class PlaybackBar extends StatefulWidget {
  const PlaybackBar({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final RoomController controller;

  /// One low line with the times on either side, for the player bar of a wide screen.
  final bool compact;

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

    final compact = widget.compact;
    final bar = LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => setState(
          () => _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth),
        ),
        onHorizontalDragUpdate: (d) => setState(
          () => _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth),
        ),
        onHorizontalDragEnd: (_) => _finish(duration),
        onHorizontalDragCancel: () => setState(() => _dragFraction = null),
        onTapUp: (d) {
          _dragFraction = _fractionAt(d.localPosition.dx, box.maxWidth);
          _finish(duration);
        },
        child: SizedBox(
          height: compact ? 20 : 28,
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(
                end: compact ? (dragging ? 6 : 4) : (dragging ? 10 : 5),
              ),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              builder: (context, height, _) => ClipRRect(
                borderRadius: BorderRadius.circular(height),
                child: Stack(
                  children: [
                    Container(height: height, color: p.outline),
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
          const SizedBox(width: 10),
          Expanded(child: bar),
          const SizedBox(width: 10),
          left,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        bar,
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [elapsed, left],
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
