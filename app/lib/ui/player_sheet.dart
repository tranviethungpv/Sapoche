import 'package:flutter/material.dart';

import 'now_playing_page.dart';
import 'scope.dart';
import 'widgets/artwork.dart';

/// The full player as a sheet inside the home screen rather than a route: a pushed route would
/// cancel the finger that is dragging it open. One animation value, 0 closed to 1 open, is the
/// sheet's position, and taps, drags and the Back button all move that same value. Listeners hear
/// when the sheet starts or stops being open.
class PlayerSheetController extends ChangeNotifier {
  PlayerSheetController(TickerProvider vsync)
    : position = AnimationController(vsync: vsync);

  final AnimationController position;

  /// Keys the cover flight measures: the mini player's cover, the full player's cover and page.
  final miniCover = GlobalKey();
  final pageCover = GlobalKey();
  final pageRoot = GlobalKey();

  /// True while a finger, or the animation that settles after it, moves the sheet. The value is
  /// then the position itself; otherwise easing curves are applied on top of it.
  bool linear = false;

  bool _open = false;
  bool _disposed = false;

  static const _openMs = 420;
  static const _closeMs = 380;
  static const _fingerMs = 380;
  static const _flingVelocity = 800.0;

  /// Being opened, or open.
  bool get isOpen => _open;

  /// Between closed and open, when the cover is in flight.
  bool get inMotion => position.value > 0 && position.value < 1;

  /// Where the sheet is after easing, 0 closed to 1 open.
  double get eased {
    final v = position.value;
    if (linear) return v;
    // Opening starts quickly and settles; closing eases in as well, so it glides rather than drops
    return position.status == AnimationStatus.reverse
        ? Curves.easeInOutCubic.transform(v)
        : Curves.easeOutCubic.transform(v);
  }

  void open() {
    _setOpen(true);
    _animate(1, ms: _openMs, byFinger: false);
  }

  void close() {
    _setOpen(false);
    _animate(0, ms: _closeMs, byFinger: false);
  }

  /// The finger has taken hold; the sheet stops wherever it was.
  void beginDrag() {
    position.stop();
    linear = true;
    _setOpen(true);
  }

  /// [dy] is the finger's vertical movement in pixels, positive downwards.
  void dragBy(double dy, double height) {
    position.value = (position.value - dy / height).clamp(0.0, 1.0);
  }

  /// [velocity] is in pixels per second, positive downwards.
  void endDrag(double velocity, {required bool startedClosed}) {
    final open = velocity.abs() > _flingVelocity
        ? velocity < 0
        : position.value > (startedClosed ? 0.4 : 0.75);
    _setOpen(open);
    _animate(open ? 1 : 0, ms: _fingerMs, byFinger: true);
  }

  @override
  void dispose() {
    _disposed = true;
    position.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    _open = open;
    notifyListeners();
  }

  void _animate(double target, {required int ms, required bool byFinger}) {
    if (_disposed) return;
    linear = byFinger;
    final distance = (position.value - target).abs();
    final duration = Duration(
      milliseconds: (ms * distance).round().clamp(120, ms),
    );
    final curve = byFinger ? Curves.easeOutCubic : Curves.linear;
    // Direction matters: the easing above reads whether the sheet is going back
    final run = target == 1
        ? position.animateTo(1, duration: duration, curve: curve)
        : position.animateBack(0, duration: duration, curve: curve);
    run.whenComplete(() => linear = false);
  }
}

class PlayerSheetScope extends InheritedWidget {
  const PlayerSheetScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final PlayerSheetController controller;

  static PlayerSheetController of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlayerSheetScope>()!
      .controller;

  @override
  bool updateShouldNotify(PlayerSheetScope old) => controller != old.controller;
}

/// Draws the sheet over the home screen, and the cover flying between the two players.
class PlayerSheetLayer extends StatelessWidget {
  const PlayerSheetLayer({super.key, required this.controller});

  final PlayerSheetController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.position,
    child: const NowPlayingPage(),
    builder: (context, page) {
      if (controller.position.value == 0) return const SizedBox.shrink();
      final closed = 1 - controller.eased;
      final linear = controller.linear;
      // Only a sheet held by a finger shrinks and rounds off; plain opening stays a pure slide
      final scale = linear ? 1 - closed * 0.08 : 1.0;
      final radius = linear ? 28 * (closed * 8).clamp(0.0, 1.0) : 0.0;
      // The flying cover is part of the sheet, so it moves with it and can never lag behind or
      // stick out past its edge
      return FractionalTranslation(
        translation: Offset(0, closed),
        child: Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: radius == 0 ? Clip.none : Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                page!,
                if (controller.inMotion) _CoverFlight(controller: controller),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The cover on its way between the mini player and its place in the full player, drawn inside
/// the sheet. It appears where the sheet's top edge meets the mini player's cover, the same spot
/// and size, then grows into place as the sheet rises; closing plays the same in reverse.
class _CoverFlight extends StatelessWidget {
  const _CoverFlight({required this.controller});

  final PlayerSheetController controller;

  RenderBox? _box(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final miniBox = _box(controller.miniCover);
    final pageBox = _box(controller.pageCover);
    final root = _box(controller.pageRoot);
    if (miniBox == null || pageBox == null || root == null) {
      return const SizedBox.shrink();
    }
    // The mini player is not inside the sheet, so this is where it is on the screen
    final mini = miniBox.localToGlobal(Offset.zero) & miniBox.size;
    // Measured inside the page, so the sheet's own movement does not enter into it
    final page = MatrixUtils.transformRect(
      pageBox.getTransformTo(root),
      Offset.zero & pageBox.size,
    );
    // How open the sheet is when its top edge is level with the mini player's cover
    final meets = 1 - mini.top / root.size.height;
    final open = controller.eased;
    if (open <= meets) return const SizedBox.shrink();
    final t = Curves.easeInOut.transform(
      ((open - meets) / (1 - meets)).clamp(0.0, 1.0),
    );
    // In the sheet's own space its top edge is 0, which is where the cover starts
    final start = Rect.fromLTWH(mini.left, 0, mini.width, mini.height);
    final rect = Rect.lerp(start, page, t)!;
    // Drawn at the full player's size and scaled down, so it is the very picture already
    // decoded there; a size that changed every frame would decode a new one each time
    final natural = pageBox.size.width;
    final radius = 8 + (16 - 8) * t;
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: FittedBox(
          child: Artwork(
            url: room.snapshot.current?.thumb,
            size: natural,
            radius: radius * natural / rect.width,
            sharp: true,
          ),
        ),
      ),
    );
  }
}

/// Hides its child while the cover is in flight, so the two are never seen at once.
class CoverSlot extends StatelessWidget {
  const CoverSlot({super.key, required this.controller, required this.child});

  final PlayerSheetController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.position,
    child: child,
    builder: (context, child) =>
        Opacity(opacity: controller.inMotion ? 0 : 1, child: child),
  );
}

/// Pull the open player down. Wraps the player page.
class PlayerPull extends StatelessWidget {
  const PlayerPull({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => sheet.beginDrag(),
      onVerticalDragUpdate: (d) => sheet.dragBy(d.delta.dy, height),
      onVerticalDragEnd: (d) =>
          sheet.endDrag(d.primaryVelocity ?? 0, startedClosed: false),
      onVerticalDragCancel: () => sheet.endDrag(0, startedClosed: false),
      child: child,
    );
  }
}

/// Drag up on a bar (the mini player) to pull the full player open under the finger.
class PlayerOpenDrag extends StatelessWidget {
  const PlayerOpenDrag({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => sheet.beginDrag(),
      onVerticalDragUpdate: (d) => sheet.dragBy(d.delta.dy, height),
      onVerticalDragEnd: (d) =>
          sheet.endDrag(d.primaryVelocity ?? 0, startedClosed: true),
      onVerticalDragCancel: () => sheet.endDrag(0, startedClosed: true),
      child: child,
    );
  }
}
