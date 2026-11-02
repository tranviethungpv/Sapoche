import 'dart:convert';

/// A version of the app that the iPhone has not got, as its release page tells it.
class ReleaseOffer {
  const ReleaseOffer({required this.version, required this.notes, required this.url});

  final String version;

  /// What the release says changed; empty when it says nothing.
  final String notes;

  /// The page of the release, where the file to install is.
  final String url;
}

/// Whether a newer version of the app is out for iPhone. An iPhone has no store: the app is put on it by SideStore from
/// the file that each release of the public repository carries, so the latest release says what is out. Nothing is
/// downloaded or installed here; the person is taken to the release.
class IosUpdateCheck {
  const IosUpdateCheck({required this.installed, required this.fetch});

  /// The version this phone runs, like `1.32.0`.
  final String installed;

  /// The body of the latest release as GitHub tells it (`/releases/latest`), or null when it could not be read.
  final Future<String?> Function() fetch;

  /// The latest release when it is newer than [installed], else null. A failure is "nothing new": a phone that cannot ask
  /// carries on.
  Future<ReleaseOffer?> newer() async {
    try {
      final body = await fetch();
      if (body == null) {
        return null;
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['draft'] == true || json['prerelease'] == true) {
        return null;
      }
      final tag = (json['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
      final url = json['html_url'] as String?;
      if (url == null || !isNewer(tag, installed)) {
        return null;
      }
      return ReleaseOffer(version: tag, notes: (json['body'] as String? ?? '').trim(), url: url);
    } on Object {
      return null;
    }
  }

  /// Whether [candidate] comes after [current], comparing `1.10.0` with `1.9.0` by number; one that is not a version is not newer.
  static bool isNewer(String candidate, String current) {
    final a = _parts(candidate);
    final b = _parts(current);
    if (a == null || b == null) {
      return false;
    }
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) {
        return a[i] > b[i];
      }
    }
    return false;
  }

  static List<int>? _parts(String version) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
    return match == null ? null : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }
}
