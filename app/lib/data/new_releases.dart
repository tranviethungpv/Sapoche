import 'dart:async';

import 'home_model.dart';
import 'music_controller.dart';
import 'music_models.dart';

/// The latest album or single of an artist the person plays.
class LatestRelease {
  const LatestRelease({
    required this.artist,
    required this.release,
    required this.year,
  });

  /// The artist as the person's own songs write the name.
  final String artist;
  final Release release;
  final int year;
}

final _year = RegExp(r'\b(19|20)\d{2}\b');

/// The year a release came out, from the line YouTube Music writes under it ("Single • 2026", or only "2020").
int? releaseYear(Release release) {
  final match = _year.firstMatch(release.subtitle ?? '');
  return match == null ? null : int.parse(match[0]!);
}

/// The newest release of each of [artists], asked for page by page: the song that starts their mix tells where their
/// page is. Only releases of [now]'s year or the year before are given, the newest first; an artist whose page cannot
/// be read, or whose latest release is older, is left out without a word.
///
/// YouTube Music gives a year, not a day, so "latest" means the latest year it lists, and among the releases of that
/// year the first it lists (it lists the newest first).
Future<List<LatestRelease>> latestReleases(
  MusicController music,
  List<ArtistMix> artists, {
  required DateTime now,
  int limit = 10,
}) async {
  Future<LatestRelease?> one(ArtistMix mix) async {
    try {
      final seed = mix.seed.videoId;
      final id = (await music.radio(seed)).songOf(seed)?.artistId;
      if (id == null) return null;
      final page = await music.artist(id);
      LatestRelease? newest;
      for (final release in [...page.singles, ...page.albums]) {
        final year = releaseYear(release);
        if (year == null || year < now.year - 1) continue;
        if (newest == null || year > newest.year) {
          newest = LatestRelease(
            artist: mix.artist,
            release: release,
            year: year,
          );
        }
      }
      return newest;
    } on Object {
      return null;
    }
  }

  final found = await Future.wait(artists.map(one));
  final releases = [
    for (final (i, r) in found.indexed)
      if (r != null) (i, r),
  ];
  // The newest year first; the artists the person plays most stay first among the releases of one year
  releases.sort((a, b) {
    final byYear = b.$2.year.compareTo(a.$2.year);
    return byYear != 0 ? byYear : a.$1.compareTo(b.$1);
  });
  return [for (final (_, r) in releases.take(limit)) r];
}
