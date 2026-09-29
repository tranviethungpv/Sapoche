import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/room_controller.dart';
import '../../format.dart';
import '../../theme/theme.dart';

/// Seek bar with elapsed and remaining time. It repaints every frame while playing so the fill
/// glides instead of jumping once a second, and it grows under the finger like Apple's.
class PlaybackBar extends StatefulWidget {
  const PlaybackBar({super.key, required this.controller});

  final RoomController controller;

  @override
  State<PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<PlaybackBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));
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
    final shouldRun = _c.player.value.playing;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
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
              height: 28,
              child: Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: dragging ? 10 : 5),
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
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatDuration(shownMs), style: _timeStyle(context)),
            Text(
              '−${formatDuration(duration - shownMs)}',
              style: _timeStyle(context),
            ),
          ],
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
