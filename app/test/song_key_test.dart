import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/song_key.dart';

Track t(String id, String title, String artist, [int seconds = 200]) =>
    Track(videoId: id, title: title, artist: artist, durMs: seconds * 1000);

void main() {
  group('the song and its official video are one song', () {
    test('tags on the title are not part of the song', () {
      expect(
        sameSong(
          t('a', 'Never Gonna Give You Up', 'Rick Astley', 213),
          t(
            'b',
            'Never Gonna Give You Up (Official Music Video)',
            'Rick Astley',
            214,
          ),
        ),
        isTrue,
      );
      expect(
        sameSong(
          t('a', 'Take On Me', 'a-ha', 226),
          t('b', 'Take On Me [Official Video] [HD]', 'a-ha - Topic', 228),
        ),
        isTrue,
      );
    });

    test('an artist in front of the title and a channel name are dropped', () {
      expect(
        sameSong(
          t('a', 'Hello', 'Adele', 295),
          t('b', 'Adele - Hello (Official Music Video)', 'AdeleVEVO', 367),
        ),
        isFalse,
        reason: 'a video 70 seconds longer is not the same recording',
      );
      expect(
        sameSong(
          t('a', 'Hello', 'Adele', 295),
          t('b', 'Adele - Hello', 'Adele VEVO', 300),
        ),
        isTrue,
      );
    });

    test('Vietnamese names match whatever the capitals and bars', () {
      expect(
        sameSong(
          t('a', 'Chúng Ta Của Hiện Tại', 'Sơn Tùng M-TP', 302),
          t(
            'b',
            'CHÚNG TA CỦA HIỆN TẠI | SƠN TÙNG M-TP | Official Music Video',
            'Sơn Tùng M-TP Official',
            303,
          ),
        ),
        isTrue,
      );
    });

    test('a featured artist does not change the song', () {
      expect(
        sameSong(
          t('a', 'Song', 'Main Artist', 200),
          t('b', 'Song (feat. Someone)', 'Main Artist, Someone', 202),
        ),
        isTrue,
      );
      expect(
        sameSong(
          t('a', 'Song', 'Main Artist', 200),
          t('b', 'Song ft. Someone', 'Main Artist & Someone', 202),
        ),
        isTrue,
      );
    });
  });

  group('other recordings stay apart', () {
    test('remixes, live versions and covers are other songs', () {
      final original = t('a', 'Song', 'Artist', 200);
      expect(
        sameSong(original, t('b', 'Song (Remix)', 'Artist', 200)),
        isFalse,
      );
      expect(sameSong(original, t('c', 'Song (Live)', 'Artist', 200)), isFalse);
      expect(
        sameSong(original, t('d', 'Song (Acoustic)', 'Artist', 200)),
        isFalse,
      );
      expect(
        sameSong(original, t('e', 'Song', 'Another Artist', 200)),
        isFalse,
      );
      expect(
        sameSong(
          t('f', 'Song (Remix)', 'Artist', 200),
          t('g', 'Song (Remix)', 'Artist', 203),
        ),
        isTrue,
      );
    });

    test(
      'the same name by another artist or of another length is another song',
      () {
        expect(
          sameSong(
            t('a', 'Yesterday', 'The Beatles', 125),
            t('b', 'Yesterday', 'Boyz II Men', 125),
          ),
          isFalse,
        );
        expect(
          sameSong(
            t('a', 'Song', 'Artist', 200),
            t('b', 'Song', 'Artist', 420),
          ),
          isFalse,
        );
      },
    );

    test('a length that is not known does not keep two songs apart', () {
      expect(
        sameSong(
          t('a', 'Song', 'Artist', 0),
          t('b', 'Song (Official Video)', 'Artist', 200),
        ),
        isTrue,
      );
    });
  });

  test('the same video is the same song', () {
    expect(sameSong(t('a', 'One', 'x'), t('a', 'Two', 'y')), isTrue);
  });

  test('uniqueSongs keeps the first of each song in order', () {
    final songs = uniqueSongs([
      t('a', 'Song', 'Artist', 200),
      t('b', 'Other', 'Artist', 180),
      t('c', 'Song (Official Video)', 'Artist', 201),
      t('d', 'Song (Remix)', 'Artist', 200),
      t('e', 'Other', 'Artist', 181),
    ]);
    expect(songs.map((s) => s.videoId), ['a', 'b', 'd']);
  });

  test('a title made only of tags keeps its words', () {
    expect(songKey('(Official)', 'Artist'), isNot(startsWith('|')));
  });
}
