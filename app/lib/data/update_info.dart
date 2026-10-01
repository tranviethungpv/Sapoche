enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  needsPermission,
  installing,
  failed,
}

/// Where an update of the app stands, as the native side reports it.
class UpdateInfo {
  const UpdateInfo({
    this.phase = UpdatePhase.idle,
    this.installed = '',
    this.version,
    this.notes,
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
  final int size;
  final int done;

  /// A short code for what went wrong, see `S.updateError`.
  final String? error;

  /// A newer version is waiting for the person, in whatever state.
  bool get hasUpdate => version != null && phase != UpdatePhase.upToDate;

  double? get progress =>
      size > 0 ? (done / size).clamp(0, 1).toDouble() : null;
}
