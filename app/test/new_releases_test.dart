import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/home_model.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/new_releases.dart';

import 'fake_backend.dart';

/// A backend that knows each artist's page by the song that starts their mix.
class _Pages extends FakeBackend {
  _Pages(this.pages);

  /// Song id → (artist id, releases); a song without an entry has no artist id.
  final Map<String, (String?, List<Release>, List<Release>)> pages;
  final failing = <String>{};

  @override
  Future<SongRadio> musicNext(String videoId) async {
    final page = pages[videoId];
    return SongRadio(
      tracks: [
        MusicTrack(
          videoId: videoId,
          title: 'T',
          artist: 'A',
          artistId: page?.$1,
          durMs: 1000,
        ),
      ],
    );
  }

  @override
  Future<ArtistPage> musicArtist(String artistId) async {
    if (failing.contains(artistId)) throw StateError('no page');
    final entry = pages.values.firstWhere((e) => e.$1 == artistId);
    return ArtistPage(
      id: artistId,
      name: artistId,
      albums: entry.$2,
      singles: entry.$3,
    );
  }
}

Release r(String title, String line) =>
    Release(id: 'id-$title', title: title, subtitle: line);

ArtistMix mix(String artist, String seed) => ArtistMix(
  artist: artist,
  seed: Track(videoId: seed, title: 'T', artist: artist, durMs: 1000),
);

void main() {
  final now = DateTime(2026, 10, 8);

  test('the year of a release is read from the line under it', () {
    expect(releaseYear(r('x', 'Single • 2026')), 2026);
    expect(releaseYear(r('x', '2020')), 2020);
    expect(releaseYear(r('x', 'Album • 1987 • 12 songs')), 1987);
    expect(releaseYear(r('x', 'Single')), isNull);
    expect(releaseYear(const Release(id: 'a', title: 'x')), isNull);
  });

  test(
    'each artist gives their newest release, the newest year first',
    () async {
      final backend = _Pages({
        's1': (
          'UC1',
          [r('Old Album', '2017')],
          [r('Single A', 'Single • 2026')],
        ),
        's2': ('UC2', [r('Album B', '2025')], [r('Single B', 'Single • 2024')]),
        's3': ('UC3', [r('Album C', '2026')], []),
      });
      final music = MusicController(backend);
      final found = await latestReleases(music, [
        mix('Alpha', 's1'),
        mix('Beta', 's2'),
        mix('Gamma', 's3'),
      ], now: now);
      expect(found.map((f) => f.release.title), [
        'Single A',
        'Album C',
        'Album B',
      ]);
      expect(found.map((f) => f.artist), ['Alpha', 'Gamma', 'Beta']);
      expect(found.map((f) => f.year), [2026, 2026, 2025]);
    },
  );

  test('a release from before last year is not new', () async {
    final backend = _Pages({
      's1': ('UC1', [r('Album', '2019')], [r('Single', 'Single • 2023')]),
    });
    final found = await latestReleases(MusicController(backend), [
      mix('Alpha', 's1'),
    ], now: now);
    expect(found, isEmpty);
  });

  test(
    'an artist whose page cannot be read is left out, not a failure',
    () async {
      final backend = _Pages({
        's1': ('UC1', [], [r('Single A', 'Single • 2026')]),
        's2': ('UC2', [], [r('Single B', 'Single • 2026')]),
        's3': (null, [], [r('Single C', 'Single • 2026')]),
      })..failing.add('UC1');
      final found = await latestReleases(MusicController(backend), [
        mix('Alpha', 's1'),
        mix('Beta', 's2'),
        mix('Gamma', 's3'),
      ], now: now);
      expect(found.map((f) => f.artist), ['Beta']);
    },
  );

  test('only as many as asked for come back', () async {
    final backend = _Pages({
      for (var i = 0; i < 5; i++)
        's$i': ('UC$i', [], [r('Single $i', 'Single • 2026')]),
    });
    final found = await latestReleases(
      MusicController(backend),
      [for (var i = 0; i < 5; i++) mix('Artist $i', 's$i')],
      now: now,
      limit: 3,
    );
    expect(found.map((f) => f.artist), ['Artist 0', 'Artist 1', 'Artist 2']);
  });
}
