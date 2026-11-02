import 'dart:convert';

/// Whether the page that is open is the newest the server has. A tab left open for days keeps the version it loaded
/// with; the server's `version.json` (which the build writes) says which one is out now.
class VersionCheck {
  const VersionCheck({required this.loaded, required this.fetch});

  /// The version this page loaded with, like `1.32.0+68`.
  final String loaded;

  /// The body of the server's `version.json`, or null when it could not be read.
  final Future<String?> Function() fetch;

  /// The version out now when it is not the one this page runs, else null. A failure is "nothing new": a page that
  /// cannot ask carries on.
  Future<String?> newer() async {
    try {
      final body = await fetch();
      if (body == null) {
        return null;
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final version = json['version'] as String?;
      final build = json['build_number']?.toString();
      if (version == null || version.isEmpty) {
        return null;
      }
      final now = build == null || build.isEmpty ? version : '$version+$build';
      return now == loaded ? null : now;
    } on Object {
      return null;
    }
  }
}
