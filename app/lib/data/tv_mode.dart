import 'package:flutter/foundation.dart';

import 'calm.dart';

/// Whether the app draws for a TV: Automatic follows the device (Android says when it is a TV or a TV box), On and Off
/// are the person's own word, for a box that does not say it is a TV, and for a browser on one.
enum TvMode { auto, on, off }

/// Whether the app is drawn for a TV. Static like [Calm], which it also moves: a TV starts with the bare effects, for the
/// weak chips of the boxes, until the person chooses.
abstract final class Tv {
  /// The device says it is a TV.
  static bool _device = false;
  static TvMode _mode = TvMode.auto;

  /// Whether the TV layout is in force.
  static final ValueNotifier<bool> on = ValueNotifier(false);

  static set device(bool value) {
    _device = value;
    _update();
  }

  static set mode(TvMode value) {
    _mode = value;
    _update();
  }

  static void _update() {
    final now = switch (_mode) {
      TvMode.on => true,
      TvMode.off => false,
      TvMode.auto => _device,
    };
    Calm.television = now;
    if (now != on.value) on.value = now;
  }
}
