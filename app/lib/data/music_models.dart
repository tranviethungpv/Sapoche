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

/// An artist, or a profile: somebody who is not an artist but puts videos and playlists up.
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
    this.shelves = const [],
    this.topSongsId,
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

  /// The other rows of the page: videos, live performances, playlists.
  final List<MusicShelf> shelves;

  /// The playlist that holds all of the top songs, of which [topSongs] are the first few.
  final String? topSongsId;

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
    shelves: _shelves(map['shelves']),
    topSongsId: map['topSongsId'] as String?,
  );
}

/// An album, single, EP or playlist: what it is, who made it and its songs. A long playlist comes a hundred songs
/// at a time: [more] is where the next ones are asked for, null when [tracks] are all of them.
class CollectionPage {
  const CollectionPage({
    required this.id,
    required this.title,
    this.kind,
    this.year,
    this.owner,
    this.ownerId,
    this.description,
    this.thumb,
    this.stats = const [],
    this.tracks = const [],
    this.more,
    this.shelves = const [],
  });

  final String id;
  final String title;

  /// What YouTube calls it: `Album`, `Single`, `EP` or `Playlist`.
  final String? kind;
  final String? year;

  /// The artist of an album, or who made the playlist, and where their page is when there is one.
  final String? owner;
  final String? ownerId;
  final String? description;
  final String? thumb;

  /// The facts under the title, like "18 songs" and "1 hour, 13 minutes".
  final List<String> stats;
  final List<MusicTrack> tracks;
  final String? more;

  /// Other rows of the page: more by the artist, similar playlists.
  final List<MusicShelf> shelves;

  factory CollectionPage.fromMap(Map<Object?, Object?> map) => CollectionPage(
    id: map['id'] as String,
    title: map['title'] as String? ?? '',
    kind: map['kind'] as String?,
    year: map['year'] as String?,
    owner: map['owner'] as String?,
    ownerId: map['ownerId'] as String?,
    description: map['description'] as String?,
    thumb: map['thumb'] as String?,
    stats: [for (final e in map['stats'] as List<Object?>? ?? const []) '$e'],
    tracks: _tracks(map['tracks']),
    more: map['more'] as String?,
    shelves: _shelves(map['shelves']),
  );
}

/// One result of a search. [kind] is `song`, `video`, `episode`, `album` (an album, single or EP), `artist`,
/// `profile` or `playlist` (a playlist or a podcast); [id] is the video to play or the page to open. [label] is what
/// YouTube calls it when it says so (`Single`, `EP`). [track] is there for what plays.
class SearchItem {
  const SearchItem({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.label,
    this.thumb,
    this.track,
  });

  final String kind;
  final String id;
  final String title;
  final String? subtitle;
  final String? label;
  final String? thumb;
  final Track? track;

  /// What a touch plays, as against what it opens.
  bool get plays => track != null;

  factory SearchItem.fromMap(Map<Object?, Object?> map) => SearchItem(
    kind: map['kind'] as String,
    id: map['id'] as String,
    title: map['title'] as String? ?? '',
    subtitle: map['subtitle'] as String?,
    label: map['label'] as String?,
    thumb: map['thumb'] as String?,
    track: map['track'] == null
        ? null
        : MusicTrack.fromMap(map['track'] as Map<Object?, Object?>),
  );
}

/// A filter YouTube Music offers for a search, and the code that asks for it.
class SearchChip {
  const SearchChip({required this.label, required this.params});

  final String label;
  final String params;
}

/// What a search found: the [top] result when YouTube picks one, the [items] in the order it lists them, and the
/// [chips] to narrow it down. [more] is where the results after these are asked for, null when these are all.
class SearchResults {
  const SearchResults({
    this.chips = const [],
    this.top,
    this.items = const [],
    this.more,
  });

  final List<SearchChip> chips;
  final SearchItem? top;
  final List<SearchItem> items;
  final String? more;

  factory SearchResults.fromMap(Map<Object?, Object?> map) => SearchResults(
    chips: [
      for (final e in map['chips'] as List<Object?>? ?? const [])
        SearchChip(
          label: (e as Map<Object?, Object?>)['label'] as String,
          params: e['params'] as String,
        ),
    ],
    top: map['top'] == null
        ? null
        : SearchItem.fromMap(map['top'] as Map<Object?, Object?>),
    items: [
      for (final e in map['items'] as List<Object?>? ?? const [])
        SearchItem.fromMap(e as Map<Object?, Object?>),
    ],
    more: map['more'] as String?,
  );
}

/// The songs after those of a [CollectionPage], and where the ones after them are (null at the end).
class MoreTracks {
  const MoreTracks({this.tracks = const [], this.more});

  final List<MusicTrack> tracks;
  final String? more;

  factory MoreTracks.fromMap(Map<Object?, Object?> map) =>
      MoreTracks(tracks: _tracks(map['tracks']), more: map['more'] as String?);
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

/// A titled row of a page: songs, albums, playlists or artists, any mix of them.
class MusicShelf {
  const MusicShelf({
    required this.title,
    this.tracks = const [],
    this.playlists = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final String title;
  final List<MusicTrack> tracks;
  final List<Release> playlists;
  final List<Release> albums;
  final List<ArtistCard> artists;

  factory MusicShelf.fromMap(Map<Object?, Object?> map) => MusicShelf(
    title: map['title'] as String? ?? '',
    tracks: _tracks(map['tracks']),
    playlists: _releases(map['playlists']),
    albums: _releases(map['albums']),
    artists: _artists(map['artists']),
  );
}

/// A mood or activity YouTube Music offers on its home page (Relax, Workout...); [params] asks for what suits it.
class MoodChip {
  const MoodChip({required this.label, required this.params});

  final String label;
  final String params;

  factory MoodChip.fromMap(Map<Object?, Object?> map) => MoodChip(
    label: map['label'] as String? ?? '',
    params: map['params'] as String? ?? '',
  );
}

/// The home page of YouTube Music: the moods it offers and its shelves; for a mood, the shelves that suit it.
class MusicHome {
  const MusicHome({this.chips = const [], this.shelves = const []});

  final List<MoodChip> chips;
  final List<MusicShelf> shelves;

  factory MusicHome.fromMap(Map<Object?, Object?> map) => MusicHome(
    chips: [
      for (final e in map['chips'] as List<Object?>? ?? const [])
        MoodChip.fromMap(e as Map<Object?, Object?>),
    ],
    shelves: _shelves(map['shelves']),
  );
}

List<MusicShelf> _shelves(Object? list) => [
  for (final e in list as List<Object?>? ?? const [])
    MusicShelf.fromMap(e as Map<Object?, Object?>),
];

/// The songs kept for one seed: a song the person likes or plays a lot, and what YouTube Music lists beside it.
/// A song or an artist the person asked not to be offered: [kind] is `song` (the key is its video id) or `artist`
/// (the key is the artist's name in plain letters, as [mainArtist] gives it).
class BlockedItem {
  const BlockedItem({
    required this.kind,
    required this.key,
    required this.label,
  });

  final String kind;
  final String key;
  final String label;

  bool get isArtist => kind == 'artist';

  factory BlockedItem.fromMap(Map<Object?, Object?> map) => BlockedItem(
    kind: map['kind'] as String? ?? 'song',
    key: map['key'] as String? ?? '',
    label: map['label'] as String? ?? '',
  );
}

/// A mix for a time of day ([bucket] is `morning`, `afternoon`, `evening` or `night`): what the person plays at
/// that hour and songs like it. No songs until enough was heard at that hour to say anything.
class ContextMix {
  const ContextMix({this.bucket = '', this.tracks = const []});

  final String bucket;
  final List<Track> tracks;

  factory ContextMix.fromMap(Map<Object?, Object?> map) => ContextMix(
    bucket: map['bucket'] as String? ?? '',
    tracks: [
      for (final e in map['tracks'] as List<Object?>? ?? const [])
        Track.fromMap(e as Map<Object?, Object?>),
    ],
  );
}

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
