import 'package:flutter/widgets.dart';

/// Scroll physics that bounce at the top of a list but stop dead at its end.
///
/// On a phone that bounces (iPhone, a browser on one) a long page whose last rows come in as it scrolls (the home page's
/// rows that wait for the network, the lazily measured rows) was thrown back up it, hundreds of points, when the
/// person pulled it past its end and let go. The page never goes past its end here, so there is no spring-back for it
/// to be thrown by; the top keeps its bounce, which pulling to refresh needs. Everything else is left to [parent],
/// the physics of the platform.
class EndClampedPhysics extends ScrollPhysics {
  const EndClampedPhysics({super.parent});

  @override
  EndClampedPhysics applyTo(ScrollPhysics? ancestor) =>
      EndClampedPhysics(parent: buildParent(ancestor));

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // At the end and pushed on, or on its way to it and pushed past: what is past the end is not scrolled
    if (position.maxScrollExtent <= position.pixels &&
        position.pixels < value) {
      return value - position.pixels;
    }
    if (position.pixels < position.maxScrollExtent &&
        position.maxScrollExtent < value) {
      return value - position.maxScrollExtent;
    }
    return super.applyBoundaryConditions(position, value);
  }
}
