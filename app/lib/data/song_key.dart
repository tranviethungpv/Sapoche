import 'models.dart';

/// Words that describe a recording or a video of it rather than the song: "(Official Video)", "[Lyrics]",
/// "(Remastered 2009)". "Remix", "Live", "Acoustic", "Cover" are not among them: those are other recordings.
final _noise = RegExp(
  r'official|video|audio|lyric|visuali[sz]er|\bm/?v\b|\bhd\b|\bhq\b|\b4k\b|remaster|\bclip\b|full (song|album)|\bfeat\b|\bft\b',
  caseSensitive: false,
);
final _brackets = RegExp(r'\s*[(\[][^)\]]*[)\]]');
final _featTail = RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false);
final _artistSplit = RegExp(
  r'\s*(?:,|&|\bx\b|\bfeat\.?|\bft\.?|\bvà\b|\band\b)\s*',
  caseSensitive: false,
);
final _channelSuffix = RegExp(
  r'\s*(?:-\s*topic|vevo|official(?:\s+channel)?)$',
  caseSensitive: false,
);
final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

String _plain(String text) =>
    text.toLowerCase().replaceAll(_punctuation, ' ').trim();

/// The first artist of a credit like "A, B & C" without "- Topic", "VEVO" or "Official", in plain letters.
String mainArtist(String credit) {
  var text = credit.trim().replaceFirst(_channelSuffix, '');
  text = text.split(_artistSplit).first.replaceFirst(_channelSuffix, '');
  return _plain(text);
}

/// The first artist of a credit as it is written, without "- Topic", "VEVO" or "Official": for showing a name.
String displayArtist(String credit) {
  final text = credit.trim().replaceFirst(_channelSuffix, '');
  return text.split(_artistSplit).first.replaceFirst(_channelSuffix, '').trim();
}

/// The title of the song in plain letters, without what only describes the recording.
String songTitle(String title, String artist) {
  var text = title.replaceAllMapped(
    _brackets,
    (m) => _noise.hasMatch(m[0]!) ? '' : m[0]!,
  );
  final artistName = mainArtist(artist);
  // "Title | Artist | AUDIO": what is left of the bars once the artist and the tags are gone
  final parts = text
      .split(RegExp(r'\s+\|\s+'))
      .where(
        (part) =>
            part.isNotEmpty &&
            !_noise.hasMatch(part) &&
            (artistName.isEmpty || _plain(part) != artistName),
      )
      .toList();
  if (parts.isNotEmpty) text = parts.first;
  // "Artist - Title"
  final dash = text.indexOf(' - ');
  if (dash > 0 &&
      artistName.isNotEmpty &&
      _plain(text.substring(0, dash)).contains(artistName)) {
    text = text.substring(dash + 3);
  }
  text = text.replaceFirst(_featTail, '');
  final plain = _plain(text);
  return plain.isEmpty ? _plain(title) : plain;
}

final _keys = <String, String>{};

/// What tells one song from another: its name and its first artist, in plain letters. Lists ask for the keys of
/// the same songs over and over as they redraw, so the last few thousand are kept.
String songKey(String title, String artist) {
  final name = '$title\u0000$artist';
  final kept = _keys.remove(name);
  if (kept != null) return _keys[name] = kept;
  if (_keys.length >= 4000) _keys.remove(_keys.keys.first);
  return _keys[name] = '${songTitle(title, artist)}|${mainArtist(artist)}';
}

/// An audio release and a video of it, or a song put on two lists twice, are one song when their names match
/// and their lengths are close: videos often start with a few seconds of something else.
bool sameSong(Track a, Track b) {
  if (a.videoId == b.videoId) return true;
  if (songKey(a.title, a.artist) != songKey(b.title, b.artist)) return false;
  if (a.durMs <= 0 || b.durMs <= 0) return true;
  final longer = a.durMs > b.durMs ? a.durMs : b.durMs;
  final tolerance = longer * 0.08 > 15000 ? longer * 0.08 : 15000;
  return (a.durMs - b.durMs).abs() <= tolerance;
}

/// [tracks] with each song once: the first of the tracks that are the same song stays, the others go.
List<T> uniqueSongs<T extends Track>(Iterable<T> tracks) {
  final byKey = <String, List<T>>{};
  final kept = <T>[];
  for (final track in tracks) {
    final same = byKey.putIfAbsent(
      songKey(track.title, track.artist),
      () => [],
    );
    if (same.any((other) => sameSong(other, track))) continue;
    same.add(track);
    kept.add(track);
  }
  return kept;
}
