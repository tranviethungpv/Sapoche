import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../theme/theme.dart';
import 'motion.dart';
import '../tv/tv.dart' show TvScope;

/// Whether the person is moving about with keys (a TV remote, a game pad, a keyboard) rather than a finger or a mouse:
/// only then is a ring drawn round what has the focus.
bool get keysAreInUse =>
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// A control that is touched with a finger and also reached with the arrow keys and pressed with OK (Enter, a game pad's
/// A): in place of a bare [GestureDetector], which a remote cannot reach. It draws nothing of its own; the ring round what
/// has the focus is [FocusRingLayer]'s.
class FocusTap extends StatelessWidget {
  const FocusTap({
    super.key,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    this.semantic = true,
    this.focusable = true,
  });

  final VoidCallback? onTap;

  /// Also run by holding OK, by the Menu key and by a game pad's X, as a touch is held.
  final VoidCallback? onLongPress;
  final Widget child;
  final HitTestBehavior behavior;

  /// False when [child] is a control with its own semantics: the place round it is then not a second one.
  final bool semantic;

  /// False when [child] has a focus of its own (a button, an ink well): the place round it is then not a second stop for
  /// the arrows on the same spot.
  final bool focusable;

  @override
  Widget build(BuildContext context) => MenuKeys(
    onMenu: onLongPress,
    child: Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      // No semantics of its own: the tap the detector says is what a screen reader hears, as it was
      child: Focus(
        canRequestFocus: onTap != null && focusable,
        includeSemantics: false,
        child: MouseRegion(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: GestureDetector(
            behavior: behavior,
            excludeFromSemantics: !semantic,
            onTap: onTap,
            onLongPress: onLongPress,
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// A card that grows a little while it has the focus, as the cards of the TV apps do. Only on a TV, and only while keys
/// are in use; elsewhere it is [child] as it is.
class FocusScale extends StatefulWidget {
  const FocusScale({super.key, required this.child, this.scale = 1.06});

  final Widget child;
  final double scale;

  @override
  State<FocusScale> createState() => _FocusScaleState();
}

class _FocusScaleState extends State<FocusScale> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!TvScope.of(context)) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: AnimatedScale(
        scale: _focused && keysAreInUse ? widget.scale : 1,
        duration: Motion.of(context, 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// What a long press is for a finger, the keys of a remote say in three ways: holding OK, the Menu key, and the X button of a
/// game pad. [onMenu] runs for any of them, and a short press of OK still goes to the control under it (as it is
/// let go, not as it is pressed, since a press that is held must not also be a tap).
class MenuKeys extends StatefulWidget {
  const MenuKeys({
    super.key,
    required this.onMenu,
    required this.child,
    this.ready,
  });

  final VoidCallback? onMenu;

  /// Asked at each key: a menu that is made only when its row is built may not be there yet, and then OK is a tap.
  final bool Function()? ready;
  final Widget child;

  /// How long OK is held to count as a long press.
  static const hold = Duration(milliseconds: 500);

  static final _ok = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  State<MenuKeys> createState() => _MenuKeysState();
}

class _MenuKeysState extends State<MenuKeys> {
  Timer? _held;
  bool _fired = false;

  @override
  void dispose() {
    _held?.cancel();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final menu = widget.onMenu;
    if (menu == null || !(widget.ready?.call() ?? true)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonX) {
      if (event is KeyDownEvent) menu();
      return KeyEventResult.handled;
    }
    if (!MenuKeys._ok.contains(key)) return KeyEventResult.ignored;
    switch (event) {
      case KeyDownEvent():
        _fired = false;
        _held?.cancel();
        _held = Timer(MenuKeys.hold, () {
          _fired = true;
          widget.onMenu?.call();
        });
      // Android sends repeats only once a key has been held down for the long-press time
      case KeyRepeatEvent():
        if (!_fired) {
          _held?.cancel();
          _fired = true;
          menu();
        }
      case KeyUpEvent():
        final tap = _held?.isActive ?? false;
        _held?.cancel();
        // Let go before the time was up: it was a tap on whatever has the focus
        final focus = node.context;
        if (tap && !_fired && focus != null) {
          final target = FocusManager.instance.primaryFocus?.context ?? focus;
          Actions.maybeInvoke(target, const ActivateIntent());
        }
      default:
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onKeyEvent: _key,
    child: widget.child,
  );
}

/// A text field on a page, as a TV has it: passed by the arrows like any other control, with no keyboard opening as the
/// focus goes over it. OK opens it for typing; up, down or leaving it closes it again. Off a TV it is the field as it was.
/// [builder] makes the field with the node and the read-only flag it is given.
class TvFieldGate extends StatefulWidget {
  const TvFieldGate({super.key, this.focusNode, required this.builder});

  /// The node the page keeps for the field, if it does.
  final FocusNode? focusNode;
  final Widget Function(FocusNode node, bool readOnly) builder;

  @override
  State<TvFieldGate> createState() => _TvFieldGateState();
}

class _TvFieldGateState extends State<TvFieldGate> {
  FocusNode? _own;
  bool _editing = false;

  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  @override
  void didUpdateWidget(TvFieldGate old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_changed);
      _node.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  /// The focus went off the field: it is closed again, for the next time the arrows pass over it.
  void _changed() {
    if (_editing && !_node.hasFocus) setState(() => _editing = false);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // Closed, the field is a control like the others: the arrows leave it (they would only move the caret in it). Open,
    // left and right are the caret's, and up and down still leave it
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft when !_editing => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight when !_editing => TraversalDirection.right,
      _ => null,
    };
    if (direction != null) {
      if (event is! KeyUpEvent) {
        Actions.maybeInvoke(
          node.context ?? context,
          DirectionalFocusIntent(direction),
        );
      }
      return KeyEventResult.handled;
    }
    final ok =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!ok || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_editing) {
      // Back to the keyboard, if it was put away with Back
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    } else {
      setState(() => _editing = true);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.of(context)) return widget.builder(_node, false);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _key,
      child: widget.builder(_node, !_editing),
    );
  }
}

/// A menu or sheet that has just opened has the focus on its own scope and no control: with keys in use the focus is put on
/// its first control once it is drawn, so that OK and the arrows work from where the person is looking.
void focusFirstOfNewRoute() {
  if (!keysAreInUse) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = FocusManager.instance.primaryFocus;
      if (node is FocusScopeNode) node.nextFocus();
    });
  });
}

/// A bar that is dragged along (the seek bar, the volume): a finger drags it, and the left and right keys move it by
/// [step] while it has the focus. Up and down are left alone, to leave it.
class KeySlider extends StatelessWidget {
  const KeySlider({
    super.key,
    required this.onStep,
    required this.child,
    this.label,
  });

  /// Called with -1 for the left key and 1 for the right key, and again while the key is held.
  final ValueChanged<int> onStep;
  final Widget child;
  final String? label;

  @override
  Widget build(BuildContext context) => Focus(
    debugLabel: label,
    onKeyEvent: (node, event) {
      if (event is KeyUpEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft) {
        onStep(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        onStep(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}

/// Draws a ring round whatever has the focus, over everything, while the person uses keys. One place for all of the app:
/// the ring does not depend on what the control is made of (an ink well, a button, a [FocusTap]). It is three
/// dp wide in the colour of the text, with a thin halo of the other colour so that it shows over a bright cover as well
/// as over the page.
class FocusRingLayer extends StatefulWidget {
  const FocusRingLayer({super.key, required this.child});

  final Widget child;

  @override
  State<FocusRingLayer> createState() => _FocusRingLayerState();
}

class _FocusRingLayerState extends State<FocusRingLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Rect? _ring;

  /// Frames the ring has stood still: a ticker that ran for ever would keep every frame coming, and a test never settle.
  int _still = 0;
  static const _stillFrames = 6;

  /// A node this much of the window is the page's own, not a control.
  static const _wholeScreen = 0.8;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_changed);
    _watch = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _recheck(),
    );
  }

  Timer? _watch;

  /// What moved under a ring that was not told (a panel opened and the buttons were laid out again).
  void _recheck() {
    if (!mounted || (_ring == null && !keysAreInUse)) return;
    final ring = _find();
    if (ring != _ring) setState(() => _ring = ring);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_changed);
    _watch?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  /// A page scrolls and a control moves under a ring that has not: after the focus moves or a page scrolls, the ring is
  /// looked at every frame until it has stood still for a few of them.
  void _changed() {
    _still = 0;
    if (!_ticker.isActive && mounted) _ticker.start();
  }

  void _tick(Duration _) {
    final ring = _find();
    if (ring != _ring) {
      _still = 0;
      setState(() => _ring = ring);
    } else if (++_still >= _stillFrames) {
      _ticker.stop();
    }
  }

  Rect? _find() {
    if (!keysAreInUse) return null;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode || !node.hasPrimaryFocus) {
      return null;
    }
    final context = node.context;
    final box = this.context.findRenderObject();
    if (context == null || !context.mounted || box is! RenderBox) return null;
    RenderObject? found = context.findRenderObject();
    // A field is ringed whole, with its border and its icons, not just the line the text is typed on
    if (context.findAncestorWidgetOfExactType<EditableText>() != null) {
      context.visitAncestorElements((element) {
        if (element.widget is! InputDecorator) return true;
        found = element.findRenderObject();
        return false;
      });
    }
    final target = found;
    if (target is! RenderBox || !target.attached || !target.hasSize) {
      return null;
    }
    final area = Offset.zero & box.size;
    final global = MatrixUtils.transformRect(
      target.getTransformTo(box),
      Offset.zero & target.size,
    );
    if (global.isEmpty ||
        global.width * global.height >
            area.width * area.height * _wholeScreen) {
      return null;
    }
    // Not under a route that has gone, or off the window altogether
    return area.overlaps(global) ? global : null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ring = _ring;
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        if (_ring != null) _changed();
        return false;
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (ring != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _RingPainter(
                    ring,
                    main: p.text,
                    halo: p.text.computeLuminance() > 0.5
                        ? const Color(0xFF000000)
                        : const Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.rect, {required this.main, required this.halo});

  final Rect rect;
  final Color main;
  final Color halo;

  /// What shape the ring has: a round control a circle, a pill a pill, anything else a rounded rectangle.
  static double radiusOf(Rect rect) {
    final low = math.min(rect.width, rect.height);
    final high = math.max(rect.width, rect.height);
    // The play disc of a TV is 108 across; a cover or a card is never so small
    if (low <= 120 && high <= low * 1.1) return low / 2;
    if (low <= 56 && high >= low * 1.8) return low / 2;
    return math.min(14, low / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // A control at the edge of the screen keeps its whole ring in view
    final inside = (Offset.zero & size).deflate(5);
    final shape = RRect.fromRectAndRadius(
      rect.inflate(2).intersect(inside),
      Radius.circular(radiusOf(rect) + 2),
    );
    canvas
      ..drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = halo.withValues(alpha: 0.4),
      )
      ..drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = main,
      );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      rect != old.rect || main != old.main || halo != old.halo;
}
