import 'package:flutter/widgets.dart';

/// Scroll physics that keep a list from flying back up when it grows under a bounce.
///
/// On a phone that bounces (iPhone, a browser on one) a list pulled past its end springs back, moving up. If the list
/// gets longer meanwhile (a row that was waiting for its answer from the network, the next page of results), the end is
/// no longer where the spring was heading: the position is in range and the scroll goes on as a plain fling, carrying
/// the speed of the spring-back up the list, hundreds of points, to the middle of it. Here that scroll stops where it
/// is, with the new rows under it.
///
/// Everything else is left to [parent], the physics of the platform.
class SettleOnGrowthPhysics extends ScrollPhysics {
  SettleOnGrowthPhysics({super.parent});

  /// Set when the list has just grown under a spring-back, and read by the [createBallisticSimulation] that follows it in
  /// the same call of the position's [ScrollPosition.applyContentDimensions]. A box, because physics are immutable.
  final _grew = _Flag();

  @override
  SettleOnGrowthPhysics applyTo(ScrollPhysics? ancestor) =>
      SettleOnGrowthPhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    // Moving back (a negative speed) from past the end, which the end has since moved away from
    _grew.set =
        isScrolling &&
        velocity < 0 &&
        oldPosition.pixels > oldPosition.maxScrollExtent &&
        newPosition.maxScrollExtent > oldPosition.maxScrollExtent &&
        newPosition.pixels <= newPosition.maxScrollExtent;
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (_grew.set) {
      _grew.set = false;
      return null;
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

class _Flag {
  bool set = false;
}
