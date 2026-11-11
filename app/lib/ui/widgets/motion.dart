import 'package:flutter/material.dart';

import '../../data/calm.dart';

/// How long things take to move, and when they do not move at all. Every motion of the interface that is not the
/// person's finger asks here: at most 300 ms, and none while the system's "reduce motion" is on or the phone is warm,
/// in battery saver or set to "Light effects" ([Calm]).
abstract final class Motion {
  static const short = 180;
  static const medium = 240;
  static const long = 300;

  static const curve = Curves.easeOutCubic;

  /// Whether motion is to be left out: the system's setting, or the phone being asked to do less.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) || Calm.on.value;

  /// [ms] milliseconds, or nothing while [reduced].
  static Duration of(BuildContext context, int ms) =>
      reduced(context) ? Duration.zero : Duration(milliseconds: ms);

  /// How a sheet rises and goes: the same for all of them.
  static AnimationStyle sheet(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 280),
          reverseDuration: Duration(milliseconds: 220),
          curve: curve,
          reverseCurve: Curves.easeInCubic,
        );
}

/// Pops its child in, small to full size with a fade, when it is first built after the page was: someone who just came
/// into the room. With [animate] false, or with motion [Motion.reduced], it is there at once.
class Pop extends StatefulWidget {
  const Pop({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<Pop> createState() => _PopState();
}

class _PopState extends State<Pop> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: Motion.long),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || !widget.animate) return;
    _started = true;
    if (Motion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    child: ScaleTransition(
      scale: Tween(begin: 0.6, end: 1.0).animate(_scale),
      child: widget.child,
    ),
  );
}
