import 'package:flutter_test/flutter_test.dart';
import 'package:unison/ui/widgets/artwork.dart';

void main() {
  test('a YouTube video thumbnail becomes the largest one of that video', () {
    expect(
      sharpThumbnail(
        'https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg?sqp=-oaymwEXCNUGEOADIAQ&rs=AOn4CLD',
      ),
      'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
    );
    expect(
      sharpThumbnail('https://i.ytimg.com/vi_webp/dQw4w9WgXcQ/mqdefault.webp'),
      'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
    );
  });

  test('a Google-hosted cover asks for a bigger size', () {
    expect(
      sharpThumbnail('https://lh3.googleusercontent.com/abc=w544-h544-l90-rj'),
      'https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj',
    );
  });

  test('any other address is left alone', () {
    for (final url in [
      'http://t/1.jpg',
      'https://example.com/vi/dQw4w9WgXcQ/x.jpg',
      'not a url',
    ]) {
      expect(sharpThumbnail(url), url);
    }
  });
}
