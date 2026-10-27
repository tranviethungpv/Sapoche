import 'package:flutter/services.dart';

/// One released version and what its notes say.
class ReleaseEntry {
  const ReleaseEntry(this.version, this.notes);

  /// `1.25.0`, without the build number.
  final String version;

  /// The notes as written: a line that starts with "- " is a bullet, any other line is a heading.
  final String notes;
}

/// The notes of every version, which ship inside the app as assets (`release-notes/<version>.txt` for English and
/// `<version>.vi.txt` for Vietnamese), so they read the same on a phone with no network and in a browser.
class ReleaseHistory {
  ReleaseHistory._();

  static const _folder = 'release-notes/';

  /// The versions, newest first, with their notes in [language] or, where there are none, in English.
  static Future<List<ReleaseEntry>> load(
    AssetBundle bundle, {
    String language = 'en',
  }) async {
    final assets = (await AssetManifest.loadFromAssetBundle(bundle))
        .listAssets()
        .where((a) => a.startsWith(_folder))
        .toSet();
    final versions = [
      for (final asset in assets)
        if (RegExp(r'^\d+(\.\d+)*\.txt$')
            .hasMatch(asset.substring(_folder.length)))
          asset.substring(_folder.length, asset.length - '.txt'.length),
    ]..sort(compare);
    return [
      for (final version in versions.reversed)
        ReleaseEntry(
          version,
          await bundle.loadString(
            assets.contains('$_folder$version.$language.txt')
                ? '$_folder$version.$language.txt'
                : '$_folder$version.txt',
          ),
        ),
    ];
  }

  /// Orders `1.9.0` before `1.10.0`: part by part, as numbers.
  static int compare(String a, String b) {
    final x = a.split('.').map(int.parse).toList();
    final y = b.split('.').map(int.parse).toList();
    for (var i = 0; i < x.length || i < y.length; i++) {
      final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
      if (c != 0) return c;
    }
    return 0;
  }
}
