import 'package:flutter/foundation.dart';

/// How much of the visual effects the app draws: all of them, a lighter set (solid bars, still player backdrop,
/// quieter motion), or the bare minimum for very weak phones (instant pages and player, flat backgrounds, no blur
/// or shadows).
enum EffectsLevel { full, light, minimal }

/// True while the screen should do less: small moving parts move at half the pace, the glass of the bars is solid,
/// the background of the player stands still. Two things turn it on: the phone is warm or in battery saver (the native
/// side says when), or the person's effects level (chosen in Settings, or picked for a weak phone until they choose).
abstract final class Calm {
  static final ValueNotifier<bool> on = ValueNotifier(false);

  /// Whether the effects are lightened for good (Light or Minimal), by the person's choice or the phone's weakness.
  static final ValueNotifier<bool> light = ValueNotifier(false);

  /// Whether the effects are at the bare minimum (Minimal): instant pages and player, flat backgrounds, no blur or
  /// shadows. Never pulled on by heat or battery saver alone; only by choice or a very weak phone.
  static final ValueNotifier<bool> minimal = ValueNotifier(false);

  /// The effects level in force (not counting temporary heat or battery saver); what Settings shows.
  static final ValueNotifier<EffectsLevel> level = ValueNotifier(
    EffectsLevel.full,
  );

  static bool _warm = false;
  static bool _weak = false;
  static bool _veryWeak = false;
  static bool _tv = false;
  static EffectsLevel? _chosen;

  /// The native side: the phone is warm or in battery saver.
  static set warm(bool value) {
    _warm = value;
    _update();
  }

  /// The native side: the phone is a weak one (little memory), which defaults to [EffectsLevel.light] unless [chosen]
  /// says otherwise.
  static set weak(bool value) {
    _weak = value;
    _update();
  }

  /// The native side: the phone is very weak (little memory and no Vulkan 1.1), which defaults to
  /// [EffectsLevel.minimal] unless [chosen] says otherwise.
  static set veryWeak(bool value) {
    _veryWeak = value;
    _update();
  }

  /// The app is drawn for a TV or a TV box, whose chips are weak and whose screen is far: the bare minimum, unless
  /// [chosen] says otherwise.
  static set television(bool value) {
    _tv = value;
    _update();
  }

  /// The person's choice in Settings; null while they have made none.
  static set chosen(EffectsLevel? value) {
    _chosen = value;
    _update();
  }

  static void _update() {
    final effective =
        _chosen ??
        (_veryWeak || _tv
            ? EffectsLevel.minimal
            : _weak
            ? EffectsLevel.light
            : EffectsLevel.full);
    level.value = effective;
    light.value = effective != EffectsLevel.full;
    minimal.value = effective == EffectsLevel.minimal;
    on.value = _warm || light.value;
  }

  /// How many times slower things move; [LowRateTimer] stretches its period by this.
  static int get slowdown => on.value ? 2 : 1;
}
