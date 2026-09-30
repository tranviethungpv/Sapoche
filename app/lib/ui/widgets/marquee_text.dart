import 'dart:async';

import 'package:flutter/material.dart';

/// One line of text that scrolls past when it does not fit, like the title in YouTube Music's player: it waits,
/// moves slowly to the end and comes round again. Text that fits stays where it is, and so does all of it when
/// the system asks for less motion (then it is cut with "…").
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.pause = const Duration(seconds: 2),
  });

  final String text;
  final TextStyle? style;

  /// How long the start of the text stays readable before it moves.
  final Duration pause;

  /// Logical pixels the text moves in a second.
  static const speed = 34.0;

  /// Room between the end of the text and its beginning coming round again.
  static const gap = 56.0;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);

  /// Bumped whenever the loop has to start again or stop, so an old loop notices and ends.
  int _run = 0;
  Timer? _wait;
  double _distance = 0;

  @override
  void dispose() {
    _run++;
    _wait?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Starts (or restarts) the loop for a line that has to travel [distance]; 0 stops it.
  void _travel(double distance) {
    if (distance == _distance) return;
    _distance = distance;
    final run = ++_run;
    _wait?.cancel();
    _controller.value = 0;
    if (distance == 0) return;
    // No frames are drawn while the text waits: only the timer runs
    void again() {
      _wait = Timer(widget.pause, () async {
        if (run != _run || !mounted) return;
        _controller.duration = Duration(
          milliseconds: (distance / MarqueeText.speed * 1000).round(),
        );
        try {
          await _controller.forward(from: 0).orCancel;
        } on TickerCanceled {
          return;
        }
        if (run != _run || !mounted) return;
        // The copy of the text that came round looks just like the start
        _controller.value = 0;
        again();
      });
    }

    again();
  }

  @override
  void didUpdateWidget(MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _travel(0);
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        final height = painter.height;
        painter.dispose();
        final fits = width <= constraints.maxWidth;
        final distance = fits || still ? 0.0 : width + MarqueeText.gap;
        // The loop is only (re)started after this frame is built
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _travel(distance);
        });
        if (distance == 0) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final line = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: style,
        );
        return ClipRect(
          child: SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final offset = _controller.value * distance;
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => LinearGradient(
                    colors: [
                      Colors.white.withValues(
                        alpha: (1 - (offset / 14).clamp(0, 1)).toDouble(),
                      ),
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0, 14 / rect.width, 1 - 14 / rect.width, 1],
                  ).createShader(rect),
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    child: Transform.translate(
                      offset: Offset(-offset, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          line,
                          const SizedBox(width: MarqueeText.gap),
                          line,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
