import '../format.dart';
import 'backend.dart';
import 'models.dart';
import 'music_models.dart';
import 'song_key.dart';

final _lyricVideo = RegExp(r'lyric', caseSensitive: false);

/// What the full player shows about a song, asked for once and kept for the next look: going back and forth
/// between the lyrics and the queue, or between songs, does not ask again. A failed ask is not kept, so
/// opening the page again tries again.
class MusicController {
  MusicController(this._backend);

  final Backend _backend;

  final _radio = <String, Future<SongRadio>>{};
  final _related = <String, Future<RelatedPage>>{};
  final _views = <String, Future<int?>>{};
  final _artists = <String, Future<ArtistPage>>{};
  final _collections = <String, Future<CollectionPage>>{};
  final _searchPages = <String, Future<SearchResults>>{};
  final _lyrics = <String, Future<Lyrics?>>{};
  final _trending = <String, Future<List<MusicShelf>>>{};
  final _homes = <String, Future<MusicHome>>{};
  final _charts = <String, Future<List<MusicShelf>>>{};
  final _searches = <String, Future<List<MusicTrack>>>{};

  static const _keep = 30;

  /// How many watched or played a track, as the list that showed it said ("59M plays"), by video id. YouTube counts a song one way in a search and another in the player (59M and 301K for the same song),
  /// so the number the person saw in the list is the one the player and the song's info use: one number for a song.
  final _seen = <String, String>{};

  // About 100 KB; kept in memory only, so that nothing is read or written when the app starts or stops
  static const _keepSeen = 2000;

  /// The count a list showed for [videoId], said in the language of the app, or null when none did.
  String? seenViews(String videoId) => splitViews(_seen[videoId]).views;

  /// The count to show beside [track]: the one its own list gave, else one a list showed earlier. Asks nothing.
  String? viewsFor(Track track) =>
      splitViews(track is MusicTrack ? track.stats : null).views ?? seenViews(track.videoId);

  void _see(Iterable<MusicTrack> tracks) {
    for (final t in tracks) {
      if (splitViews(t.stats).views == null) continue;
      _seen
        ..remove(t.videoId)
        ..[t.videoId] = t.stats!;
    }
    while (_seen.length > _keepSeen) {
      _seen.remove(_seen.keys.first);
    }
  }

  void _seeShelves(Iterable<MusicShelf> shelves) {
    for (final shelf in shelves) {
      _see(shelf.tracks);
    }
  }

  SearchResults _seeResults(SearchResults results) {
    _see([
      for (final item in [results.top, ...results.items])
        if (item?.track case final MusicTrack track) track,
    ]);
    return results;
  }

  Future<SongRadio> radio(String videoId) =>
      _cached(_radio, videoId, () => _backend.musicNext(videoId)).then((radio) {
        _see(radio.tracks);
        return radio;
      });

  /// How many times the video was watched or the song played, once YouTube has said; not kept while it has not.
  Future<int?> views(String videoId) => _cached(
    _views,
    videoId,
    () => _backend.musicViews(videoId),
    keep: (count) => count != null,
  );

  /// How many watched [track], with whether it is a song, for which the count is of plays and not of views. Null when
  /// YouTube does not say, or there is no network.
  Future<({int count, bool plays})?> viewCount(Track track) async {
    try {
      final count = await views(track.videoId);
      if (count == null) return null;
      final plays = await isAudioRelease(track).then<bool?>((v) => v, onError: (_) => null);
      return (count: count, plays: plays ?? false);
    } catch (_) {
      return null;
    }
  }

  Future<RelatedPage> related(String videoId) =>
      _cached(_related, videoId, () => _backend.musicRelated(videoId));

  Future<ArtistPage> artist(String artistId) =>
      _cached(_artists, artistId, () => _backend.musicArtist(artistId)).then((page) {
        _see(page.topSongs);
        _seeShelves(page.shelves);
        return page;
      });

  Future<CollectionPage> collection(String id) =>
      _cached(_collections, id, () => _backend.musicCollection(id)).then((page) {
        _see(page.tracks);
        _seeShelves(page.shelves);
        return page;
      });

  /// What YouTube Music finds for [query], all of it or one kind with [params]; the same answer when asked again.
  Future<SearchResults> searchPage(String query, {String? params}) => _cached(
    _searchPages,
    '${params ?? ''}\n$query',
    () => _backend.musicSearchPage(query, params: params),
  ).then(_seeResults);

  /// The results after those a page of a search has; asked for as the person scrolls, so not kept.
  Future<SearchResults> searchMore(String token) =>
      _backend.musicSearchMore(token).then(_seeResults);

  /// The songs after those a page has; asked for as the person scrolls, so not kept.
  Future<MoreTracks> more(String token) => _backend.musicMore(token).then((more) {
    _see(more.tracks);
    return more;
  });

  /// What YouTube Music shows everybody; the same answer for the rest of the session.
  Future<List<MusicShelf>> trending() =>
      _cached(_trending, 'home', _backend.musicTrending).then((shelves) {
        _seeShelves(shelves);
        return shelves;
      });

  /// The moods YouTube Music offers, with its home page; with a mood's [params] the shelves that suit that mood.
  Future<MusicHome> home({String? params}) => _cached(
    _homes,
    params ?? '',
    () => _backend.musicHome(params: params),
    keep: (home) => home.chips.isNotEmpty || home.shelves.isNotEmpty,
  ).then((home) {
    _seeShelves(home.shelves);
    return home;
  });

  /// The charts of the person's country; the same answer for the rest of the session.
  Future<List<MusicShelf>> charts() => _cached(
    _charts,
    'charts',
    _backend.musicCharts,
    keep: (shelves) => shelves.isNotEmpty,
  ).then((shelves) {
    _seeShelves(shelves);
    return shelves;
  });

  Future<List<MusicTrack>> search(String query, {required bool songs}) =>
      _cached(
        _searches,
        '$songs $query',
        () => _backend.musicSearch(query, songs: songs),
      ).then((tracks) {
        _see(tracks);
        return tracks;
      });

  /// Whether [track] is the audio release of a song (true) or a video (false); null when YouTube Music does not say.
  Future<bool?> isAudioRelease(Track track) async =>
      (await radio(track.videoId)).songOf(track.videoId)?.isSong;

  /// The audio release a music video was found for, by the video's id: going back to it needs no search, so the cover
  /// of the video (a still of it, cut square) is not what the person looks at while YouTube Music is asked.
  final _audioOf = <String, MusicTrack>{};

  /// The audio release that [video] was found from, or null when it was not.
  MusicTrack? audioOf(Track video) => _audioOf[video.videoId];

  /// The other release of [track]: the music video of a song when [video], else the audio release of a video.
  /// Null when YouTube Music has no such release of it.
  Future<MusicTrack?> otherRelease(Track track, {required bool video}) async {
    final kept = video ? null : audioOf(track);
    if (kept != null) return kept;
    final found = await _findRelease(track, video: video);
    if (video && found != null) {
      _audioOf[found.videoId] = MusicTrack(
        videoId: track.videoId,
        title: track.title,
        artist: track.artist,
        durMs: track.durMs,
        thumb: track.thumb,
        isSong: true,
      );
    }
    return found;
  }

  Future<MusicTrack?> _findRelease(Track track, {required bool video}) async {
    final name =
        '${songTitle(track.title, track.artist)} ${displayArtist(track.artist)}';
    final found = await search(name, songs: !video);
    final same = found.where(
      (t) =>
          t.videoId != track.videoId && t.isSong != video && sameSong(track, t),
    );
    // A video that only shows the words is the last resort
    return same.where((t) => !_lyricVideo.hasMatch(t.title)).firstOrNull ??
        same.firstOrNull;
  }

  Future<Lyrics?> lyrics(Track track) =>
      _cached(_lyrics, track.videoId, () => _backend.lyrics(track));

  Future<T> _cached<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() load, {
    bool Function(T value)? keep,
  }) {
    final kept = cache.remove(key);
    if (kept != null) {
      // Put back at the end: the most recently used stay
      return cache[key] = kept;
    }
    final future = load();
    future.then<void>(
      // An answer that holds nothing is most likely a page that could not be read: it is asked for again
      (value) {
        if (keep != null && !keep(value)) cache.remove(key);
      },
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
