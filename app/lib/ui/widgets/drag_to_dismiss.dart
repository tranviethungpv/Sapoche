import 'package:flutter/material.dart';

/// Lets a full-screen page be pulled down with the finger. It follows the finger, shrinks a little,
/// and either flies off and pops the route (far enough or flung) or springs back.
class DragToDismiss extends StatefulWidget {
  const DragToDismiss({super.key, required this.child});

  final Widget child;

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(vsync: this)
    ..addListener(
      () => setState(
        () => _dy =
            _from +
            (_to - _from) * Curves.easeOutCubic.transform(_settle.value),
      ),
    );

  double _dy = 0;
  double _from = 0;
  double _to = 0;

  static const _flingVelocity = 800.0;
  static const _dismissFraction = 0.25;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _animateTo(double target, {required VoidCallback? then}) {
    _from = _dy;
    _to = target;
    _settle
      ..duration = const Duration(milliseconds: 220)
      ..forward(from: 0).whenComplete(() => then?.call());
  }

  void _end(double velocity, double height) {
    if (velocity > _flingVelocity || _dy > height * _dismissFraction) {
      _animateTo(
        height,
        then: () {
          if (mounted) Navigator.of(context).maybePop();
        },
      );
    } else {
      _animateTo(0, then: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final progress = (_dy / height).clamp(0.0, 1.0);
    return GestureDetector(
      onVerticalDragStart: (_) => _settle.stop(),
      onVerticalDragUpdate: (d) =>
          setState(() => _dy = (_dy + d.delta.dy).clamp(0.0, height)),
      onVerticalDragEnd: (d) => _end(d.primaryVelocity ?? 0, height),
      onVerticalDragCancel: () => _end(0, height),
      child: Transform.translate(
        offset: Offset(0, _dy),
        child: Transform.scale(
          scale: 1 - progress * 0.08,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(progress == 0 ? 0 : 28),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
