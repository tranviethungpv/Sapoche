
import '../music_models.dart';
import 'lyrics_client.dart';
import 'music_client.dart';
import 'music_parser.dart';

/// What the full player and the discovery pages show. Every answer is kept for a while, so going back and forth
/// between songs, or opening the same page twice, does not ask again. Mirrors MusicFeed.kt, without the files the lyrics
/// are kept in: [MusicController] keeps them while the page is open.
class MusicFeed {
  MusicFeed(this._music, this._lyrics, {int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MusicClient _music;
  final LyricsClient _lyrics;
  final int Function() _now;

  final _next = _Recent<String, WatchNext>();
  final _related = _Recent<String, Related>();
  final _artists = _Recent<String, ArtistPage>();
  final _collections = _Recent<String, CollectionPage>();
  final _searches = _Recent<String, SearchResults>();
  final _homes = <String, (int, MusicHome)>{};
  (int, List<MusicShelf>)? _chartsKept;

  /// The home page of YouTube Music changes by the hour at most.
  static const trendingMs = 6 * 60 * 60 * 1000;

  /// How many pages of a search are read to get as many results as asked for.
  static const maxSearchPages = 10;

  /// The radio of the song, with where its lyrics and related page are.
  Future<WatchNext> watchNext(String videoId) => _next.getOrPut(videoId, () => _music.watchNext(videoId));

  Future<Related?> related(String videoId) async {
    final page = (await watchNext(videoId)).relatedId;
    if (page == null) return null;
    return _related.getOrPut(page, () => _music.related(page));
  }

  Future<ArtistPage> artist(String artistId) => _artists.getOrPut(artistId, () => _music.artist(artistId));

  /// An album or a playlist, with its first songs.
  Future<CollectionPage> collection(String id) => _collections.getOrPut(id, () => _music.collection(id));

  /// The next songs of a long playlist; asked for as the person scrolls, so not kept.
  Future<MoreTracks> more(String token) => _music.more(token);

  Future<List<MusicShelf>> trending(String language) async => (await home(language)).shelves;

  /// The home page with its moods, or the shelves of one mood; kept for [trendingMs], one answer per language and mood.
  Future<MusicHome> home(String language, [String? params]) async {
    final key = '$language\n${params ?? ''}';
    final kept = _homes[key];
    if (kept != null && _now() - kept.$1 < trendingMs) return kept.$2;
    final home = await _music.home(language, params);
    _homes[key] = (_now(), home);
    return home;
  }

  Future<List<MusicShelf>> charts() async {
    final kept = _chartsKept;
    if (kept != null && _now() - kept.$1 < trendingMs) return kept.$2;
    final shelves = await _music.charts();
    _chartsKept = (_now(), shelves);
    return shelves;
  }

  /// Everything matching [query], or only what [params] (a filter of the page) keeps.
  Future<SearchResults> searchPage(String query, String? params) =>
      _searches.getOrPut('${params ?? ''}\n$query', () => _music.searchPage(query, params));

  /// The results after those of [searchPage]; asked for as the person scrolls, so not kept.
  Future<SearchResults> searchMore(String token) => _music.searchMore(token);

  /// Songs (audio releases) or videos matching [query], as many as [limit] over as many pages as it takes.
  Future<List<MusicTrack>> tracks(String query, {required bool songs, required int limit}) async {
    var page = await searchPage(query, songs ? MusicClient.songsFilter : MusicClient.videosFilter);
    final found = <MusicTrack>[];
    for (var i = 0; i < maxSearchPages; i++) {
      for (final item in page.items) {
        final track = item.track;
        if (track is MusicTrack && track.durMs > 0 && (item.kind == 'song' || item.kind == 'video' || item.kind == 'episode')) {
          found.add(track);
        }
      }
      final more = page.more;
      if (found.length >= limit || more == null) break;
      page = await searchMore(more);
    }
    return found.length > limit ? found.sublist(0, limit) : found;
  }

  /// The lyrics of a song: lyrics with times when LRCLIB has them, else the plain words YouTube Music has, else null.
  /// When LRCLIB cannot be reached (a blocker in the browser, or the service is down) the plain words still show;
  /// the failure is only told when there is nothing else to show.
  Future<Lyrics?> lyrics(String videoId, String title, String artist, int durationSec) async {
    Lyrics? timed;
    Object? failure;
    try {
      timed = await _lyrics.find(title, artist, durationSec);
    } on Object catch (e) {
      failure = e;
    }
    if (timed != null && timed.synced) return timed;
    final plain = await _plainFromYoutube(videoId);
    if (plain != null) return plain;
    if (failure != null) throw failure;
    return timed;
  }

  Future<Lyrics?> _plainFromYoutube(String videoId) async {
    final page = (await watchNext(videoId)).lyricsId;
    final words = page == null ? null : await _music.lyrics(page);
    return words == null ? null : Lyrics(plain: words);
  }
}

/// The last few answers, oldest let go first.
class _Recent<K, V extends Object> {
  _Recent({this.size = 24});

  final int size;
  final _map = <K, V>{};

  Future<V> getOrPut(K key, Future<V> Function() load) async {
    final kept = _map.remove(key);
    if (kept != null) {
      _map[key] = kept; // most recently used goes last
      return kept;
    }
    final value = await load();
    _map[key] = value;
    while (_map.length > size) {
      _map.remove(_map.keys.first);
    }
    return value;
  }
}
