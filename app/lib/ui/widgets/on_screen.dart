import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Tells [builder] whether the widget is inside the scrollable that holds it. A list keeps building rows a little beyond
/// its edges, so this is how a moving picture knows to stand still once it is scrolled out of sight.
class OnScreen extends StatefulWidget {
  const OnScreen({super.key, required this.builder});

  final Widget Function(BuildContext context, bool visible) builder;

  @override
  State<OnScreen> createState() => _OnScreenState();
}

class _OnScreenState extends State<OnScreen> {
  ScrollPosition? _position;
  bool _visible = true;
  bool _checking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_changed);
      _position = position?..addListener(_changed);
    }
    _changed();
  }

  @override
  void dispose() {
    _position?.removeListener(_changed);
    super.dispose();
  }

  /// Looks again after the frame, when what moved has been laid out.
  void _changed() {
    if (_checking) return;
    _checking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checking = false;
      if (mounted) _check();
    });
  }

  void _check() {
    final box = context.findRenderObject();
    final scroller = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || scroller is! RenderBox) return;
    if (!box.attached || !box.hasSize || !scroller.attached || !scroller.hasSize) return;
    final mine = box.localToGlobal(Offset.zero) & box.size;
    final view = scroller.localToGlobal(Offset.zero) & scroller.size;
    final visible = mine.overlaps(view);
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _visible);
}
