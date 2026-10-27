import 'release_history.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  needsPermission,
  installing,
  failed;

  /// The phase for a name from the native side; spelled with or without underscores, in any case.
  /// An unknown name is [idle]: showing "nothing going on" is better than an error page.
  static UpdatePhase parse(String? name) {
    final wanted = name?.replaceAll('_', '').toLowerCase();
    return values.firstWhere(
      (phase) => phase.name.toLowerCase() == wanted,
      orElse: () => idle,
    );
  }
}

/// Where an update of the app stands, as the native side reports it.
class UpdateInfo {
  const UpdateInfo({
    this.phase = UpdatePhase.idle,
    this.installed = '',
    this.version,
    this.notes,
    this.upcoming = const [],
    this.size = 0,
    this.done = 0,
    this.error,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
    phase: UpdatePhase.values.asNameMap()[json['phase']] ?? UpdatePhase.idle,
    installed: json['installed'] as String? ?? '',
    version: json['version'] as String?,
    notes: (json['notes'] as String?)?.trim().isEmpty ?? true
        ? null
        : json['notes'] as String,
    upcoming: [
      for (final item in json['upcoming'] as List<dynamic>? ?? const [])
        if (item is Map<String, dynamic> && item['version'] is String)
          ReleaseEntry(
            item['version'] as String,
            item['notes'] as String? ?? '',
          ),
    ],
    size: (json['size'] as num?)?.toInt() ?? 0,
    done: (json['done'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );

  final UpdatePhase phase;

  /// The version this phone runs.
  final String installed;

  /// The newer version on offer, if there is one.
  final String? version;
  final String? notes;

  /// What each version newer than this one changed, newest first, in the language of the app: the notes of this
  /// phone's own versions are in the app, these are the ones it cannot have.
  final List<ReleaseEntry> upcoming;
  final int size;
  final int done;

  /// A short code for what went wrong, see `S.updateError`.
  final String? error;

  /// A newer version is waiting for the person, in whatever state.
  bool get hasUpdate => version != null && phase != UpdatePhase.upToDate;

  double? get progress =>
      size > 0 ? (done / size).clamp(0, 1).toDouble() : null;
}
