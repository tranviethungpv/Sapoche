import 'update_info.dart';

/// When the sheet about a new version may come up. It is asked once for each version and then again only after
/// [every], so that nobody who said "later" is nagged, and only while there is something to do about it.
class UpdateNudge {
  UpdateNudge._();

  static const every = Duration(days: 3);

  /// [lastShown] is when the sheet last came up for this version, null if it never has.
  static bool due(
    UpdateInfo info, {
    required DateTime? lastShown,
    required DateTime now,
  }) {
    if (info.version == null) {
      return false;
    }
    if (info.phase != UpdatePhase.ready &&
        info.phase != UpdatePhase.available) {
      return false;
    }
    return lastShown == null || now.difference(lastShown) >= every;
  }
}
