import 'package:flutter/material.dart';

import '../../data/tv_mode.dart';

/// The height of the canvas the app is drawn on a TV, in dp. Every TV is drawn as this and scaled up to its screen, so
/// that one layout and one size of text serve a 720p box and a 4K set alike (Android TV's own canvas is 960x540).
const tvCanvasHeight = 540.0;

/// How far from the edge of its list or page a control is left when the arrows scroll it into view, in canvas dp: Flutter
/// scrolls just far enough to show it, which leaves a control flush with the edge of the screen and its ring cut off.
const tvScrollMargin = 32.0;

/// Moves the focus as Flutter does, then scrolls every list over it a little further if the control is within
/// [tvScrollMargin] of an edge of that list.
void tvRequestFocus(
  FocusNode node, {
  ScrollPositionAlignmentPolicy? alignmentPolicy,
  double? alignment,
  Duration? duration,
  Curve? curve,
}) {
  FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
    node,
    alignmentPolicy: alignmentPolicy,
    alignment: alignment,
    duration: duration,
    curve: curve,
  );
  final context = node.context;
  final target = context?.findRenderObject();
  if (context == null || target is! RenderBox || !target.hasSize) return;
  context.visitAncestorElements((element) {
    if (element is! StatefulElement || element.state is! ScrollableState) {
      return true;
    }
    final scrollable = element.state as ScrollableState;
    final viewport = scrollable.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return true;
    final box = MatrixUtils.transformRect(
      target.getTransformTo(viewport),
      Offset.zero & target.size,
    );
    final horizontal =
        axisDirectionToAxis(scrollable.axisDirection) == Axis.horizontal;
    final start = horizontal ? box.left : box.top;
    final end = horizontal ? box.right : box.bottom;
    final extent = horizontal ? viewport.size.width : viewport.size.height;
    var delta = 0.0;
    if (end > extent - tvScrollMargin) delta = end - (extent - tvScrollMargin);
    // Never push the start out of view to make room for the end
    if (start - delta < tvScrollMargin) delta = start - tvScrollMargin;
    if (delta != 0) {
      final reversed = axisDirectionIsReversed(scrollable.axisDirection);
      final position = scrollable.position;
      position.jumpTo(
        (position.pixels + (reversed ? -delta : delta)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
    return true;
  });
}

/// Tells the screens under it whether they are drawn for a TV.
class TvScope extends InheritedWidget {
  const TvScope({super.key, required this.on, required super.child});

  final bool on;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvScope>()?.on ?? false;

  @override
  bool updateShouldNotify(TvScope old) => on != old.on;
}

/// Draws the app on a canvas of the same height on every TV, and scales it to the screen: the window the app sees is
/// [tvCanvasHeight] dp high, text and controls included. Off a TV the app is drawn as it is.
class TvCanvas extends StatefulWidget {
  const TvCanvas({super.key, required this.child});

  final Widget child;

  @override
  State<TvCanvas> createState() => _TvCanvasState();
}

class _TvCanvasState extends State<TvCanvas> {
  /// Keeps the app's own state while the canvas comes and goes (the setting is changed with the app open).
  final _app = GlobalKey();

  @override
  void initState() {
    super.initState();
    Tv.on.addListener(_strategy);
    _strategy();
  }

  @override
  void dispose() {
    Tv.on.removeListener(_strategy);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    super.dispose();
  }

  /// A TV has no finger: whatever sends the keys (a remote, a phone's remote app that sends them as a virtual keyboard,
  /// which Flutter does not count as a keyboard), the ring is drawn round what has the focus.
  void _strategy() => FocusManager.instance.highlightStrategy = Tv.on.value
      ? FocusHighlightStrategy.alwaysTraditional
      : FocusHighlightStrategy.automatic;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: Tv.on,
    builder: (context, on, _) {
      final app = KeyedSubtree(key: _app, child: widget.child);
      if (!on) return TvScope(on: false, child: app);
      final media = MediaQuery.of(context);
      final k = media.size.height / tvCanvasHeight;
      if (k <= 0) return TvScope(on: true, child: app);
      final size = Size(media.size.width / k, tvCanvasHeight);
      return TvScope(
        on: true,
        child: MediaQuery(
          data: media.copyWith(
            size: size,
            devicePixelRatio: media.devicePixelRatio * k,
            padding: media.padding / k,
            viewPadding: media.viewPadding / k,
            viewInsets: media.viewInsets / k,
            systemGestureInsets: media.systemGestureInsets / k,
          ),
          child: SizedBox(
            width: media.size.width,
            height: media.size.height,
            child: FittedBox(
              fit: BoxFit.fill,
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: size,
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(
                    requestFocusCallback: tvRequestFocus,
                  ),
                  child: app,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
