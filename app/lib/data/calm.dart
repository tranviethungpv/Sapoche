import 'package:flutter/foundation.dart';

/// True while the screen should do less: small moving parts move at half the pace, the glass of the bars is solid,
/// the background of the player stands still. Two things turn it on: the phone is warm or in battery saver (the native
/// side says when), or the person chose "Light effects" in Settings, which a weak phone is given until they say otherwise.
abstract final class Calm {
  static final ValueNotifier<bool> on = ValueNotifier(false);

  /// Whether the effects are lightened for good, by the person's choice or the phone's weakness; what Settings shows.
  static final ValueNotifier<bool> light = ValueNotifier(false);

  static bool _warm = false;
  static bool _weak = false;
  static bool? _chosen;

  /// The native side: the phone is warm or in battery saver.
  static set warm(bool value) {
    _warm = value;
    _update();
  }

  /// The native side: the phone is a weak one (little memory), which lightens the effects unless [chosen] says otherwise.
  static set weak(bool value) {
    _weak = value;
    _update();
  }

  /// The person's choice in Settings; null while they have made none.
  static set chosen(bool? value) {
    _chosen = value;
    _update();
  }

  static void _update() {
    light.value = _chosen ?? _weak;
    on.value = _warm || light.value;
  }

  /// How many times slower things move; [LowRateTimer] stretches its period by this.
  static int get slowdown => on.value ? 2 : 1;
}
