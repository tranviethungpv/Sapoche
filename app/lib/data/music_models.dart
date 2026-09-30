import 'models.dart';

/// A song as YouTube Music describes it: the same as [Track] plus where it is from.
class MusicTrack extends Track {
  const MusicTrack({
    required super.videoId,
    required super.title,
    required super.artist,
    required super.durMs,
    super.thumb,
    this.artistId,
    this.album,
    this.albumId,
    this.year,
    this.stats,
    this.isSong = false,
  });

  /// Where the artist's page is; null when YouTube does not say.
  final String? artistId;
  final String? album;
  final String? albumId;
  final String? year;

  /// What a video's reach looks like, e.g. "1.8B views · 19M likes".
  final String? stats;

  /// The audio release of a song, as against a video of it.
  final bool isSong;

  factory MusicTrack.fromMap(Map<Object?, Object?> map) => MusicTrack(
    videoId: map['videoId'] as String,
    title: map['title'] as String,
    artist: map['artist'] as String? ?? '',
    thumb: map['thumb'] as String?,
    durMs: (map['durMs'] as num?)?.toInt() ?? 0,
    artistId: map['artistId'] as String?,
    album: map['album'] as String?,
    albumId: map['albumId'] as String?,
    year: map['year'] as String?,
    stats: map['stats'] as String?,
    isSong: map['isSong'] as bool? ?? false,
  );
}

List<MusicTrack> _tracks(Object? list) => [
  for (final e in list as List<Object?>? ?? const [])
    MusicTrack.fromMap(e as Map<Object?, Object?>),
];

/// An artist, or a channel that puts music out.
class ArtistCard {
  const ArtistCard({
    required this.id,
    required this.name,
    this.subtitle,
    this.thumb,
  });

  final String id;
  final String name;
  final String? subtitle;
  final String? thumb;

  factory ArtistCard.fromMap(Map<Object?, Object?> map) => ArtistCard(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    subtitle: map['subtitle'] as String?,
    thumb: map['thumb'] as String?,
  );
}

List<ArtistCard> _artists(Object? list) => [
  for (final e in list as List<Object?>? ?? const [])
    ArtistCard.fromMap(e as Map<Object?, Object?>),
];

/// An album, single or playlist on a page.
class Release {
  const Release({
    required this.id,
    required this.title,
    this.subtitle,
    this.thumb,
  });

  final String id;
  final String title;
  final String? subtitle;
  final String? thumb;

  factory Release.fromMap(Map<Object?, Object?> map) => Release(
    id: map['id'] as String,
    title: map['title'] as String? ?? '',
    subtitle: map['subtitle'] as String?,
    thumb: map['thumb'] as String?,
  );
}

List<Release> _releases(Object? list) => [
  for (final e in list as List<Object?>? ?? const [])
    Release.fromMap(e as Map<Object?, Object?>),
];

/// The radio of a song: what YouTube Music would play after it, the song itself first.
class SongRadio {
  const SongRadio({
    this.tracks = const [],
    this.hasLyrics = false,
    this.hasRelated = false,
  });

  final List<MusicTrack> tracks;
  final bool hasLyrics;
  final bool hasRelated;

  /// The song the radio was made for, when it comes first as it should.
  MusicTrack? songOf(String videoId) =>
      tracks.isNotEmpty && tracks.first.videoId == videoId
      ? tracks.first
      : null;

  factory SongRadio.fromMap(Map<Object?, Object?> map) => SongRadio(
    tracks: _tracks(map['tracks']),
    hasLyrics: map['hasLyrics'] as bool? ?? false,
    hasRelated: map['hasRelated'] as bool? ?? false,
  );
}

/// The "related" page of a song.
class RelatedPage {
  const RelatedPage({
    this.more = const [],
    this.otherPerformances = const [],
    this.artists = const [],
    this.playlists = const [],
    this.about,
  });

  final List<MusicTrack> more;
  final List<MusicTrack> otherPerformances;
  final List<ArtistCard> artists;
  final List<Release> playlists;

  /// Text about the artist.
  final String? about;

  bool get isEmpty =>
      more.isEmpty &&
      otherPerformances.isEmpty &&
      artists.isEmpty &&
      about == null;

  factory RelatedPage.fromMap(Map<Object?, Object?> map) => RelatedPage(
    more: _tracks(map['more']),
    otherPerformances: _tracks(map['otherPerformances']),
    artists: _artists(map['artists']),
    playlists: _releases(map['playlists']),
    about: map['about'] as String?,
  );
}

class ArtistPage {
  const ArtistPage({
    required this.id,
    required this.name,
    this.description,
    this.subscribers,
    this.thumb,
    this.topSongs = const [],
    this.albums = const [],
    this.singles = const [],
    this.similar = const [],
  });

  final String id;
  final String name;
  final String? description;
  final String? subscribers;
  final String? thumb;
  final List<MusicTrack> topSongs;
  final List<Release> albums;
  final List<Release> singles;
  final List<ArtistCard> similar;

  factory ArtistPage.fromMap(Map<Object?, Object?> map) => ArtistPage(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    description: map['description'] as String?,
    subscribers: map['subscribers'] as String?,
    thumb: map['thumb'] as String?,
    topSongs: _tracks(map['topSongs']),
    albums: _releases(map['albums']),
    singles: _releases(map['singles']),
    similar: _artists(map['similar']),
  );
}

/// One line of a song, sung from [ms] on.
class LyricLine {
  const LyricLine(this.ms, this.text);

  final int ms;
  final String text;
}

/// The words of a song: [lines] with times when they run along with the music, else only [plain].
class Lyrics {
  const Lyrics({this.lines = const [], this.plain});

  final List<LyricLine> lines;
  final String? plain;

  bool get synced => lines.isNotEmpty;

  /// The line being sung at [positionMs]: the last one that has begun. Null before the first.
  int? lineAt(int positionMs) {
    var low = 0;
    var high = lines.length - 1;
    int? found;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].ms <= positionMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  factory Lyrics.fromMap(Map<Object?, Object?> map) => Lyrics(
    lines: [
      for (final e in map['lines'] as List<Object?>? ?? const [])
        LyricLine(
          ((e as List<Object?>)[0] as num).toInt(),
          e[1] as String? ?? '',
        ),
    ],
    plain: map['plain'] as String?,
  );
}

/// A titled row of a home page: songs, playlists, or both.
class MusicShelf {
  const MusicShelf({
    required this.title,
    this.tracks = const [],
    this.playlists = const [],
  });

  final String title;
  final List<MusicTrack> tracks;
  final List<Release> playlists;

  factory MusicShelf.fromMap(Map<Object?, Object?> map) => MusicShelf(
    title: map['title'] as String? ?? '',
    tracks: _tracks(map['tracks']),
    playlists: _releases(map['playlists']),
  );
}

/// The songs kept for one seed: a song the person likes or plays a lot, and what YouTube Music lists beside it.
class SeedList {
  const SeedList({required this.seed, required this.tracks});

  final String seed;
  final List<Track> tracks;

  factory SeedList.fromMap(Map<Object?, Object?> map) => SeedList(
    seed: map['seed'] as String,
    tracks: [
      for (final e in map['tracks'] as List<Object?>? ?? const [])
        Track.fromMap(e as Map<Object?, Object?>),
    ],
  );
}
