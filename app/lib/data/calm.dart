import 'package:flutter/foundation.dart';

/// True while the phone is warm or in battery saver: small moving parts of the screen then move at half the
/// pace, which is the only part of the screen that does anything while a song plays. The native side says when.
abstract final class Calm {
  static final ValueNotifier<bool> on = ValueNotifier(false);

  /// How many times slower things move; [LowRateTimer] stretches its period by this.
  static int get slowdown => on.value ? 2 : 1;
}
