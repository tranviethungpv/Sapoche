import 'backend.dart';
import 'models.dart';
import 'music_models.dart';

/// What the full player shows about a song, asked for once and kept for the next look: going back and forth
/// between the lyrics and the queue, or between songs, does not ask again. A failed ask is not kept, so
/// opening the page again tries again.
class MusicController {
  MusicController(this._backend);

  final Backend _backend;

  final _radio = <String, Future<SongRadio>>{};
  final _related = <String, Future<RelatedPage>>{};
  final _artists = <String, Future<ArtistPage>>{};
  final _lyrics = <String, Future<Lyrics?>>{};
  final _trending = <String, Future<List<MusicShelf>>>{};
  final _searches = <String, Future<List<MusicTrack>>>{};

  static const _keep = 30;

  Future<SongRadio> radio(String videoId) =>
      _cached(_radio, videoId, () => _backend.musicNext(videoId));

  Future<RelatedPage> related(String videoId) =>
      _cached(_related, videoId, () => _backend.musicRelated(videoId));

  Future<ArtistPage> artist(String artistId) =>
      _cached(_artists, artistId, () => _backend.musicArtist(artistId));

  /// What YouTube Music shows everybody; the same answer for the rest of the session.
  Future<List<MusicShelf>> trending() =>
      _cached(_trending, 'home', _backend.musicTrending);

  Future<List<MusicTrack>> search(String query, {required bool songs}) =>
      _cached(
        _searches,
        '$songs $query',
        () => _backend.musicSearch(query, songs: songs),
      );

  Future<Lyrics?> lyrics(Track track) =>
      _cached(_lyrics, track.videoId, () => _backend.lyrics(track));

  Future<T> _cached<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() load,
  ) {
    final kept = cache.remove(key);
    if (kept != null) {
      // Put back at the end: the most recently used stay
      return cache[key] = kept;
    }
    final future = load();
    future.then<void>(
      (_) {},
      onError: (_) {
        cache.remove(key);
      },
    );
    cache[key] = future;
    while (cache.length > _keep) {
      cache.remove(cache.keys.first);
    }
    return future;
  }
}
