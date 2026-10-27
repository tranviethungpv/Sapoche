import 'dart:convert';

import '../music_models.dart';
import 'song_names.dart';

/// Reads the `[mm:ss.xx] words` format that lyrics with times come in. Mirrors Lrc in Lyrics.kt.
abstract final class Lrc {
  static final _tag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

  /// Lines in time order. A line with several times gives one line for each; tags like `[ar:Name]` are skipped.
  static List<LyricLine> parse(String text) {
    final lines = <LyricLine>[];
    for (final line in const LineSplitter().convert(text)) {
      final words = line.replaceAll(_tag, '').trim();
      for (final tag in _tag.allMatches(line)) {
        // ".5" is half a second and ".500" too
        final fraction = int.tryParse((tag[3] ?? '').padRight(3, '0').substring(0, 3)) ?? 0;
        final ms = (int.parse(tag[1]!) * 60 + int.parse(tag[2]!)) * 1000 + fraction;
        lines.add(LyricLine(ms, words));
      }
    }
    // Lines of the same time stay in the order they were written, which `sort` alone does not promise
    final order = {for (var i = 0; i < lines.length; i++) lines[i]: i};
    lines.sort((a, b) => a.ms != b.ms ? a.ms.compareTo(b.ms) : order[a]!.compareTo(order[b]!));
    return lines;
  }
}

/// Gets one address and gives its text, or null when there is nothing there (404).
typedef LyricsFetch = Future<String?> Function(String url);

/// Lyrics that run along with the music, from [LRCLIB](https://lrclib.net): a free service kept by volunteers that
/// needs no key and lets any page ask. It is told the title, artist and length of the song, nothing else.
///
/// LRCLIB answers 503 ("the server is busy, please retry in a moment") to the first ask for a song it has not looked up
/// lately, and the same ask a moment later is answered at once. So an ask that failed is made again after each of
/// [retryDelays] before it is given up.
/// Mirrors LyricsClient in Lyrics.kt.
class LyricsClient {
  LyricsClient(this._fetch, {this.retryDelays = defaultRetryDelays});

  final LyricsFetch _fetch;
  final List<Duration> retryDelays;

  static const defaultRetryDelays = [Duration(milliseconds: 600), Duration(milliseconds: 1200)];

  /// Lyrics of a song this much longer or shorter are probably of another recording.
  static const maxLengthGapSec = 5;

  /// The lyrics of the song, or null when LRCLIB has none. The exact name is tried first, then the name without tags.
  Future<Lyrics?> find(String title, String artist, int durationSec) async {
    final names = <(String, String)>{(title, artist), (SongNames.title(title, artist: artist), SongNames.artist(artist))}.toList();
    for (final (t, a) in names) {
      final found = await _exact(t, a, durationSec);
      if (found != null) return found;
    }
    final (t, a) = names.last;
    return _closest(t, a, durationSec);
  }

  Future<Lyrics?> _exact(String title, String artist, int durationSec) async {
    final body = await _get(_url('get', {
      'track_name': title,
      'artist_name': artist,
      if (durationSec > 0) 'duration': '$durationSec',
    }));
    if (body == null) return null;
    final item = jsonDecode(body);
    return item is Map<String, Object?> ? _lyricsOf(item) : null;
  }

  /// With no exact match, the song of about the same length that has the most to show.
  Future<Lyrics?> _closest(String title, String artist, int durationSec) async {
    final body = await _get(_url('search', {'track_name': title, 'artist_name': artist}));
    if (body == null) return null;
    final items = jsonDecode(body);
    if (items is! List) return null;
    final found = [
      for (final item in items)
        if (item is Map<String, Object?> &&
            (durationSec <= 0 || (((item['duration'] as num?) ?? 0) - durationSec).abs() <= maxLengthGapSec))
          ?_lyricsOf(item),
    ];
    for (final lyrics in found) {
      if (lyrics.synced) return lyrics;
    }
    return found.firstOrNull;
  }

  Future<String?> _get(String url) async {
    for (final wait in retryDelays) {
      try {
        return await _fetch(url);
      } on Object {
        await Future<void>.delayed(wait);
      }
    }
    return _fetch(url);
  }

  Lyrics? _lyricsOf(Map<String, Object?> item) {
    if (item['instrumental'] == true) return null;
    final synced = item['syncedLyrics'];
    final lines = synced is String ? Lrc.parse(synced) : const <LyricLine>[];
    final words = item['plainLyrics'];
    final plain = words is String && words.trim().isNotEmpty ? words : null;
    return lines.isEmpty && plain == null ? null : Lyrics(lines: lines, plain: plain);
  }

  static String _url(String path, Map<String, String> query) =>
      Uri.https('lrclib.net', '/api/$path', query).toString();
}
