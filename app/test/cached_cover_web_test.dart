import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/cached_cover.dart';

void main() {
  test('a failed thumbnail from YouTube stays a failure in a browser', () {
    // Its 404 for a size a video lacks has a 120x90 picture as the body, which an <img> would stretch over the cover
    for (final url in [
      'https://i.ytimg.com/vi/Z8pMSslQpKM/maxresdefault.jpg',
      'https://i9.ytimg.com/vi_webp/Z8pMSslQpKM/mqdefault.webp',
    ]) {
      expect(CachedCover.strategyFor(url), WebHtmlElementStrategy.never);
    }
  });

  test('any other picture may still be shown by the browser when it cannot be read', () {
    for (final url in [
      'https://lh3.googleusercontent.com/abc=w544-h544',
      'https://notytimg.com/vi/x/maxresdefault.jpg',
      'not a url',
    ]) {
      expect(CachedCover.strategyFor(url), WebHtmlElementStrategy.fallback);
    }
  });
}
