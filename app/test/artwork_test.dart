import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/cached_cover.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/artwork.dart';

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

  test('a thumbnail without black bars is the one sized 320 by 180', () {
    expect(
      barlessThumbnail('https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg'),
      'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
    );
    expect(
      barlessThumbnail('https://lh3.googleusercontent.com/abc=w544-h544'),
      'https://lh3.googleusercontent.com/abc=w544-h544',
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

  group(
    'a 4:3 YouTube thumbnail, whose picture sits between two black bars',
    () {
      const bars = 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg';

      Future<(String, bool)> shown(
        WidgetTester tester,
        String url,
        double size, {
        bool sharp = false,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Palette.dark),
            home: Artwork(url: url, size: size, sharp: sharp),
          ),
        );
        final image = tester.widget<Image>(find.byType(Image)).image;
        final address =
            (image is ResizeImage ? image.imageProvider : image) as CachedCover;
        final zoomed = find
            .descendant(
              of: find.byType(Artwork),
              matching: find.byType(Transform),
            )
            .evaluate()
            .any((e) => (e.widget as Transform).transform.storage[0] > 1.3);
        return (address.url, zoomed);
      }

      testWidgets('a small cover asks for the one without bars', (
        tester,
      ) async {
        expect(await shown(tester, bars, 56), (
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
          false,
        ));
      });

      testWidgets(
        'a big cover keeps the picture and zooms to between the bars',
        (tester) async {
          expect(await shown(tester, bars, 190), (bars, true));
        },
      );

      testWidgets('a picture that has no bars is left as it is', (
        tester,
      ) async {
        for (final url in [
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg?sqp=x',
          'https://lh3.googleusercontent.com/abc=w544-h544',
        ]) {
          expect(await shown(tester, url, 190), (url, false), reason: url);
        }
      });

      testWidgets(
        'a sharp cover asks for the biggest picture, which has none',
        (tester) async {
          expect(await shown(tester, bars, 300, sharp: true), (
            'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
            false,
          ));
        },
      );
    },
  );

  group('a song with no picture', () {
    for (final crossfade in [false, true]) {
      testWidgets(
        'has a tile of the cover\'s size${crossfade ? ', also in a cross-fade' : ''}',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(Palette.dark),
              home: Center(
                child: Artwork(
                  url: null,
                  size: 300,
                  radius: 16,
                  crossfade: crossfade,
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            tester.getSize(find.byType(ColoredBox).last),
            const Size(300, 300),
          );
        },
      );
    }
  });
}
