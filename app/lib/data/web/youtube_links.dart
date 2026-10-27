/// Picks video and playlist ids out of whatever the user pasted. Mirrors YoutubeLinks.kt and YoutubeLinks in YouTube.swift.
abstract final class YoutubeLinks {
  static final _videoLinks = [
    RegExp(r'youtube\.com/watch\?(?:.*&)?v=([A-Za-z0-9_-]{11})'),
    RegExp(r'youtu\.be/([A-Za-z0-9_-]{11})'),
    RegExp(r'youtube\.com/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})'),
  ];
  static final _playlistLink = RegExp(r'youtube\.com/playlist\?(?:.*&)?list=([A-Za-z0-9_-]{10,})');
  static final _bareId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// The playlist id of a link to a playlist page. A video opened inside a playlist is just that video.
  static String? playlistId(String text) => _playlistLink.firstMatch(text)?.group(1);

  /// The video id of a video link, or of a bare id. Null for anything else, including ordinary search words.
  static String? videoId(String text) {
    for (final pattern in _videoLinks) {
      final id = pattern.firstMatch(text)?.group(1);
      if (id != null) return id;
    }
    // A bare id must not be an ordinary 11 letter word from a search: real ids nearly always have a digit, _ or -
    return _bareId.hasMatch(text) && text.contains(RegExp(r'[0-9_-]')) ? text : null;
  }
}
