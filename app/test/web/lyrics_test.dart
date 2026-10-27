import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/web/lyrics_client.dart';
import 'package:sapoche/data/web/song_names.dart';

/// The same cases as LyricsTest.kt: the Dart copy of the lyrics must behave as the Kotlin and Swift ones.
void main() {
  test('lines are read with their times in order', () {
    final lines = Lrc.parse('[ar:Someone]\n[00:12.50] Second\n[00:01.00]First\n[01:02.05]Third');
    expect(lines.map((l) => (l.ms, l.text)), [(1000, 'First'), (12500, 'Second'), (62050, 'Third')]);
  });

  test('a line with several times is sung each time', () {
    final lines = Lrc.parse('[00:10.00][00:30.00]Chorus');
    expect(lines.map((l) => (l.ms, l.text)), [(10000, 'Chorus'), (30000, 'Chorus')]);
  });

  test('an empty line is kept as a pause and fractions are read as they are', () {
    expect(Lrc.parse('[00:05.5]\n[00:06.01]x').map((l) => (l.ms, l.text)), [(5500, ''), (6010, 'x')]);
  });

  test('lines of the same time stay in the order they were written', () {
    final text = [for (var i = 0; i < 40; i++) '[00:01.00]line $i'].join('\n');
    expect(Lrc.parse(text).map((l) => l.text), [for (var i = 0; i < 40; i++) 'line $i']);
  });

  test('text that is not lyrics with times gives no lines', () {
    expect(Lrc.parse('Just words\nmore words'), isEmpty);
  });

  const synced = '{"duration":213.0,"instrumental":false,"plainLyrics":"One\\nTwo","syncedLyrics":"[00:01.00] One\\n[00:02.00] Two"}';

  /// A LRCLIB that answers with the first of [answers] whose key is in the address, and keeps what it was asked.
  (LyricsClient, List<String>) lrclib(Map<String, String> answers) {
    final asked = <String>[];
    final client = LyricsClient((url) async {
      asked.add(url);
      for (final e in answers.entries) {
        if (url.contains(e.key)) return e.value;
      }
      return null;
    });
    return (client, asked);
  }

  test('an exact match gives the lyrics with times', () async {
    final (client, _) = lrclib({'api/get': synced});
    final lyrics = (await client.find('Song', 'Artist', 214))!;
    expect(lyrics.synced, isTrue);
    expect(lyrics.lines.map((l) => l.text), ['One', 'Two']);
    expect(lyrics.plain, 'One\nTwo');
  });

  test('the service is told the name and the length and nothing else', () async {
    final (client, asked) = lrclib({'api/get': synced});
    await client.find('Song', 'Artist', 214);
    expect(asked.single, 'https://lrclib.net/api/get?track_name=Song&artist_name=Artist&duration=214');
  });

  test('when the name with tags is not known the name without them is tried', () async {
    final (client, asked) = lrclib({'track_name=Song&artist_name=Artist&': synced});
    final lyrics = await client.find('Song (Official Video)', 'Artist - Topic', 214);
    expect(lyrics!.synced, isTrue);
    expect(asked, hasLength(2));
  });

  test('without an exact match the nearest length with lines wins', () async {
    const search = '''[
      {"duration":300.0,"plainLyrics":"far","syncedLyrics":"[00:01.00] far"},
      {"duration":212.0,"plainLyrics":"plain only","syncedLyrics":null},
      {"duration":215.0,"plainLyrics":"near","syncedLyrics":"[00:01.00] near"}
    ]''';
    final (client, _) = lrclib({'api/search': search});
    expect((await client.find('Song', 'Artist', 214))!.lines.single.text, 'near');
  });

  test('lyrics of a much longer recording are not used', () async {
    const search = '[{"duration":400.0,"plainLyrics":"other","syncedLyrics":"[00:01.00] other"}]';
    final (client, _) = lrclib({'api/search': search});
    expect(await client.find('Song', 'Artist', 214), isNull);
  });

  test('an instrumental and a song nobody wrote down give nothing', () async {
    const instrumental = '{"duration":214.0,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}';
    expect(await lrclib({'api/get': instrumental}).$1.find('Song', 'Artist', 214), isNull);
    expect(await lrclib({}).$1.find('Song', 'Artist', 214), isNull);
  });

  test('plain words are kept when there are no times', () async {
    const plain = '{"duration":214.0,"plainLyrics":"Only words","syncedLyrics":null}';
    final lyrics = (await lrclib({'api/get': plain}).$1.find('Song', 'Artist', 214))!;
    expect(lyrics.synced, isFalse);
    expect(lyrics.plain, 'Only words');
  });

  test('a song of unknown length is asked for without one', () async {
    final (client, asked) = lrclib({'api/get': synced});
    await client.find('Song', 'Artist', 0);
    expect(asked.single, isNot(contains('duration')));
  });

  test('a name with spaces and letters with marks is sent whole', () async {
    final (client, asked) = lrclib({});
    await client.find('Lạc Trôi', 'Sơn Tùng M-TP', 272);
    final url = Uri.parse(asked.first);
    expect(url.queryParameters, {'track_name': 'Lạc Trôi', 'artist_name': 'Sơn Tùng M-TP', 'duration': '272'});
  });

  test('tags that only describe the recording are taken off the title', () {
    expect(SongNames.title('Never Gonna Give You Up (Official Video)'), 'Never Gonna Give You Up');
    expect(SongNames.title('Take On Me [Official Music Video] [HD]'), 'Take On Me');
    expect(SongNames.title('Song (feat. Someone)'), 'Song');
    expect(SongNames.title('Song (2009 Remaster)'), 'Song');
    expect(SongNames.title('Song (Remix)'), 'Song (Remix)', reason: 'a remix is another recording');
    expect(SongNames.title('Song (Live)'), 'Song (Live)');
    expect(SongNames.title('(Official)'), '(Official)', reason: 'never leaves nothing');
  });

  test('a leading artist name is dropped from the title', () {
    expect(SongNames.title('Adele - Hello', artist: 'Adele'), 'Hello');
    expect(SongNames.title('A - B', artist: 'Someone else'), 'A - B');
  });

  test('the first artist is the main one', () {
    expect(SongNames.artist('Sơn Tùng M-TP'), 'Sơn Tùng M-TP');
    expect(SongNames.artist('Rick Astley - Topic'), 'Rick Astley');
    expect(SongNames.artist('Adele VEVO'), 'Adele');
    expect(SongNames.artist('A, B & C'), 'A');
    expect(SongNames.artist('A feat. B'), 'A');
    expect(SongNames.artist('Wham!'), 'Wham!');
    expect(SongNames.artist('Min và Đen Vâu'), 'Min');
    expect(SongNames.artist('Alex'), 'Alex', reason: 'the x of a name is not a separator');
  });

  /// A LRCLIB that is busy for its first [failures] asks, as it is for a song it has not looked up lately.
  (LyricsClient, List<String>) busy(int failures) {
    final asked = <String>[];
    final client = LyricsClient((url) async {
      asked.add(url);
      if (asked.length <= failures) throw Exception('LRCLIB answered 503');
      return synced;
    }, retryDelays: const [Duration.zero, Duration.zero]);
    return (client, asked);
  }

  test('a busy service is asked again before the lyrics are given up', () async {
    final (client, asked) = busy(2);
    expect((await client.find('Song', 'Artist', 214))!.synced, isTrue);
    expect(asked.length, 3);
  });

  test('a service that stays down is given up after the last retry', () async {
    final (client, asked) = busy(99);
    await expectLater(client.find('Song', 'Artist', 214), throwsException);
    expect(asked.length, 3);
  });

  test('the lyrics know the line that is being sung', () {
    final lyrics = Lyrics(lines: Lrc.parse('[00:01.00]a\n[00:05.00]b'));
    expect(lyrics.lineAt(500), isNull);
    expect(lyrics.lineAt(1000), 0);
    expect(lyrics.lineAt(9000), 1);
  });
}
