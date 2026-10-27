/// Titles and artists as people type them on YouTube, brought closer to what a song is called. Mirrors SongNames.kt.
abstract final class SongNames {
  /// Words that describe a recording or a video of it, not the song: "(Official Video)", "[Lyrics]", "(Remastered 2009)".
  /// `\b` knows only ASCII letters in a browser, which is enough for these words.
  static final _noise = RegExp(
    r'official|video|audio|lyric|visuali[sz]er|\bm/?v\b|\bhd\b|\bhq\b|\b4k\b|remaster|\bclip\b|full (song|album)|\bfeat\b|\bft\b',
    caseSensitive: false,
  );
  static final _brackets = RegExp(r'\s*[(\[][^)\]]*[)\]]');

  /// "và" is written with spaces around it instead of `\b`, which does not see the "à" as a letter in a browser.
  static final _artistSplit = RegExp(r'\s*(?:,|&|\bx\b|\bfeat\.?|\bft\.?|\s+và\s+|\band\b)\s*', caseSensitive: false);
  static final _channelSuffix = RegExp(r'\s*(?:-\s*topic|vevo|official(?:\s+channel)?)$', caseSensitive: false);

  /// The title without bracketed tags that only describe the recording. "Remix", "Live" and "Acoustic" stay:
  /// they are other recordings. With [artist], a leading "Artist - " is dropped too.
  static String title(String raw, {String? artist}) {
    var text = raw.replaceAllMapped(_brackets, (m) => _noise.hasMatch(m[0]!) ? '' : m[0]!).trim();
    final dash = text.indexOf(' - ');
    if (dash > 0 && artist != null) {
      final main = SongNames.artist(artist);
      if (main.isNotEmpty && text.substring(0, dash).toLowerCase().contains(main.toLowerCase())) {
        text = text.substring(dash + 3).trim();
      }
    }
    return text.isEmpty ? raw.trim() : text;
  }

  /// The first artist of a credit like "A, B & C", without "- Topic", "VEVO" or "Official".
  static String artist(String raw) {
    final first = raw.trim().replaceAll(_channelSuffix, '').split(_artistSplit).first;
    return first.replaceAll(_channelSuffix, '').trim();
  }
}
