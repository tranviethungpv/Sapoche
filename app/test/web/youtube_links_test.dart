import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/youtube_links.dart';

// Ported from YoutubeLinksTest.kt

void main() {
  test('finds the video in the usual link shapes', () {
    const id = 'bNp9pn0ni3I';
    expect(YoutubeLinks.videoId('https://www.youtube.com/watch?v=$id'), id);
    expect(YoutubeLinks.videoId('https://music.youtube.com/watch?v=$id&si=abc'), id);
    expect(YoutubeLinks.videoId('https://m.youtube.com/watch?feature=share&v=$id'), id);
    expect(YoutubeLinks.videoId('https://youtu.be/$id?t=42'), id);
    expect(YoutubeLinks.videoId('https://www.youtube.com/shorts/$id'), id);
    expect(YoutubeLinks.videoId(id), id);
  });

  test('search words are not mistaken for a video id', () {
    expect(YoutubeLinks.videoId('Radioactive'), isNull);
    expect(YoutubeLinks.videoId('son tung mtp'), isNull);
    expect(YoutubeLinks.videoId('https://example.com/watch?v=short'), isNull);
  });

  test('a playlist page gives its id but a video inside a playlist does not', () {
    const list = 'PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf';
    expect(YoutubeLinks.playlistId('https://www.youtube.com/playlist?list=$list'), list);
    expect(YoutubeLinks.playlistId('https://music.youtube.com/playlist?list=$list&si=x'), list);
    expect(YoutubeLinks.playlistId('https://www.youtube.com/watch?v=bNp9pn0ni3I&list=$list'), isNull);
    expect(YoutubeLinks.videoId('https://www.youtube.com/watch?v=bNp9pn0ni3I&list=$list'), 'bNp9pn0ni3I');
  });
}
