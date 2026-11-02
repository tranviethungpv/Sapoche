import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/models.dart';

ChatMessage _with(Map<String, dynamic>? x) => ChatMessage(id: 1, by: 'a', name: 'A', text: 'stand-in', at: 1, x: x);

AlbumItem _item(String m) => AlbumItem(m: m, key: 'k', sha: 's', mime: 'image/jpeg', w: 300, h: 400, n: 9000, th: 'AAAA');

void main() {
  test('a song, an album and a sticker are read and written back the same', () {
    const song = SongExtra(videoId: 'bNp9pn0ni3I', title: 'T', artist: 'A', durMs: 200000, art: 'https://i.ytimg.com/x');
    final read = ChatExtra.of(_with(song.toJson()));
    expect(read, isA<SongExtra>());
    expect((read as SongExtra).toJson(), song.toJson());
    expect(read.track.videoId, 'bNp9pn0ni3I');

    final album = AlbumExtra(items: [_item('a'), _item('b')], caption: 'Trip');
    final back = ChatExtra.of(_with(album.toJson()))! as AlbumExtra;
    expect(back.items.map((i) => i.m), ['a', 'b']);
    expect(back.caption, 'Trip');
    expect(back.toJson(), album.toJson());

    const sticker = StickerExtra(pack: 'noto', sticker: '1f600', emoji: '😀');
    expect((ChatExtra.of(_with(sticker.toJson()))! as StickerExtra).toJson(), sticker.toJson());
  });

  test('plain words, a kind nobody knows and a damaged extra are no extra at all', () {
    expect(ChatExtra.of(_with(null)), isNull);
    expect(ChatExtra.of(_with({'k': 'poll', 'q': '?'})), isNull);
    expect(ChatExtra.of(_with({'k': 'song'})), isNull, reason: 'a song with no video id');
    expect(ChatExtra.of(_with({'k': 'album', 'items': <dynamic>[]})), isNull, reason: 'an album with nothing in it');
    expect(ChatExtra.of(_with({'k': 'album', 'items': List.generate(11, (i) => _item('$i').toJson())})), isNull);
  });

  test('a picture of a wide or tall shape is kept within what a bubble can show', () {
    expect(const AlbumItem(m: 'a', key: 'k', sha: 's', mime: 'image/jpeg', w: 4000, h: 100, n: 1, th: '').aspect, 2.0);
    expect(const AlbumItem(m: 'a', key: 'k', sha: 's', mime: 'image/jpeg', w: 100, h: 4000, n: 1, th: '').aspect, 0.5);
    expect(const AlbumItem(m: 'a', key: 'k', sha: 's', mime: 'image/jpeg', w: 0, h: 0, n: 1, th: '').aspect, 1);
    expect(_item('a').animated, isFalse);
    expect(const AlbumItem(m: 'a', key: 'k', sha: 's', mime: 'image/gif', w: 1, h: 1, n: 1, th: '').animated, isTrue);
  });
}
