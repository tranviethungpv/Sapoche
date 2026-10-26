import 'dart:convert';

import '../music_models.dart';
import 'music_parser.dart';

/// Sends a request to YouTube Music and gives back the answer text.
typedef MusicTransport = Future<String> Function(String endpoint, String body);

/// YouTube Music as the website asks it, for a person who is not signed in: this is what gives radios, the related
/// page, lyrics and artists. It is not a documented API and can change, so the readers in [MusicParser] give what they
/// find and callers treat failure as "nothing to show". Mirrors MusicClient.kt.
class MusicClient {
  MusicClient(this._transport, {String Function()? region}) : _region = region ?? (() => 'US');

  final MusicTransport _transport;

  /// The country whose music is shown first, as a code like "VN".
  final String Function() _region;

  static const clientName = 'WEB_REMIX';

  /// The version of the website the answers are shaped for; YouTube Music stops answering very old ones.
  static const clientVersion = '1.20250310.01.00';

  /// The search filters of the website's "Songs" and "Videos" chips.
  static const songsFilter = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static const videosFilter = 'EgWKAQIQAWoKEAkQBRAKEAMQBA==';

  Future<WatchNext> watchNext(String videoId, {bool radio = true}) async => MusicParser.watchNext(
    await _ask('next', {
      'videoId': videoId,
      'isAudioOnly': true,
      if (radio) 'playlistId': 'RDAMVM$videoId',
    }),
  );

  Future<Related> related(String relatedId) async => MusicParser.related(await _browse(relatedId));

  Future<String?> lyrics(String lyricsId) async => MusicParser.lyrics(await _browse(lyricsId));

  Future<ArtistPage> artist(String artistId) async => MusicParser.artist(artistId, await _browse(artistId));

  Future<CollectionPage> collection(String id) async => MusicParser.collection(
    id,
    await _browse(id.startsWith('MPRE') || id.startsWith('MPSP') || id.startsWith('VL') ? id : 'VL$id'),
  );

  Future<MoreTracks> more(String token) async =>
      MusicParser.continuation(await _ask('browse', {'continuation': token}));

  Future<SearchResults> searchPage(String query, String? params) async =>
      MusicParser.searchPage(await _ask('search', {'query': query, 'params': ?params}));

  Future<SearchResults> searchMore(String token) async =>
      MusicParser.searchMore(await _ask('search', {'continuation': token}));

  Future<List<MusicTrack>> searchSongs(String query) async =>
      MusicParser.search(await _ask('search', {'query': query, 'params': songsFilter}));

  Future<List<MusicTrack>> searchVideos(String query) async =>
      MusicParser.search(await _ask('search', {'query': query, 'params': videosFilter}));

  // Only the shelf names of this page are meant to be read by a person; everything else is found by the words
  // YouTube Music uses in English ("Lyrics", "Related"), so those calls stay in English
  Future<List<MusicShelf>> trending([String language = 'en']) async =>
      MusicParser.shelves(await _ask('browse', {'browseId': 'FEmusic_home'}, language));

  Future<MusicHome> home([String language = 'en', String? params]) async =>
      MusicParser.home(await _ask('browse', {'browseId': 'FEmusic_home', 'params': ?params}, language));

  Future<List<MusicShelf>> charts() async => MusicParser.charts(await _browse('FEmusic_charts'));

  Future<Object?> _browse(String id) => _ask('browse', {'browseId': id});

  Future<Object?> _ask(String endpoint, Map<String, Object?> fields, [String language = 'en']) async {
    final region = _region();
    final body = jsonEncode({
      'context': {
        'client': {
          'clientName': clientName,
          'clientVersion': clientVersion,
          'hl': language,
          'gl': region.isEmpty ? 'US' : region,
        },
      },
      ...fields,
    });
    return jsonDecode(await _transport(endpoint, body));
  }
}
