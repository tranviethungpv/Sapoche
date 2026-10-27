import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/library_store.dart';
import 'package:sapoche/data/web/suggestion_feed.dart';
import 'package:sapoche/data/web/wire.dart';

// What SuggestionFeed.kt does, for the Dart copy

const hour = 60 * 60 * 1000;

Track song(String id, String artist) => Track(videoId: id, title: 'Song $id', artist: artist, durMs: 200000);

TrackRef ref(String id, String artist, {int sec = 200}) => TrackRef(id, 'Song $id', artist, null, sec * 1000);

void main() {
  var clock = 100 * 24 * hour;
  late LibraryStore library;
  late Map<String, List<TrackRef>> radios;
  late List<String> asked;
  late SuggestionFeed feed;

  setUp(() {
    clock = 100 * 24 * hour;
    // The library keeps its own times: the feed's clock and the library's are the same one
    library = LibraryStore(nowMs: () => clock);
    radios = {};
    asked = [];
    feed = SuggestionFeed(
      store: library,
      now: () => clock,
      radio: (id) async {
        asked.add(id);
        final list = radios[id];
        if (list == null) throw StateError('no radio');
        return list;
      },
    );
  });

  test('nothing is offered until something was heard and its radio was fetched', () async {
    expect(feed.forYou(), isEmpty);
    library.recordListen(song('a', 'Known'));
    expect(feed.forYou(), isEmpty, reason: 'the radio of the seed was not fetched yet');
    radios['a'] = [ref('x', 'New'), ref('y', 'Newer')];
    expect(await feed.renew(force: false), isTrue);
    expect(feed.forYou().map((t) => t.videoId), unorderedEquals(['x', 'y']));
  });

  test('a list that is fresh is not fetched again, an old one is, and force fetches it anyway', () async {
    library.recordListen(song('a', 'Known'));
    radios['a'] = [ref('x', 'New')];
    await feed.renew(force: false);
    expect(asked, ['a']);
    clock += hour;
    expect(await feed.renew(force: false), isFalse);
    expect(asked, ['a']);
    expect(await feed.renew(force: true), isTrue);
    expect(asked, ['a', 'a']);
    clock += 13 * hour;
    await feed.renew(force: false);
    expect(asked.length, 3);
  });

  test('one seed that fails does not stop the others, and keeps what it had', () async {
    library
      ..recordListen(song('a', 'A'))
      ..recordListen(song('b', 'B'))
      ..recordListen(song('b', 'B'));
    radios['a'] = [ref('x', 'New')];
    radios['b'] = [ref('y', 'Newer')];
    await feed.renew(force: false);
    radios.remove('b');
    clock += 13 * hour;
    await feed.renew(force: false);
    expect(feed.forYou().map((t) => t.videoId), unorderedEquals(['x', 'y']));
  });

  test('clips and hour long mixes are not kept as suggestions', () async {
    library.recordListen(song('a', 'Known'));
    radios['a'] = [ref('clip', 'N', sec: 20), ref('mix', 'M', sec: 3600), ref('ok', 'O')];
    await feed.renew(force: false);
    expect(feed.forYou().map((t) => t.videoId), ['ok']);
  });

  test('what plays on after a song leaves out what was heard this week and what is blocked', () async {
    library
      ..recordListen(song('h', 'Heard'))
      ..block(SuggestionFeed.artist, 'blocked', 'Blocked');
    radios['s'] = [ref('h', 'Heard'), ref('b', 'Blocked'), ref('k', 'Fine'), ref('q', 'Fine Two'), ref('s', 'Itself')];
    final more = await feed.after('s', {'q'}, 10);
    expect(more.map((t) => t.videoId), ['k']);
  });

  test('a mix for this time of day is empty until enough was heard at this hour', () async {
    final (bucket, tracks) = await feed.contextMix();
    expect(bucket, isNotEmpty);
    expect(tracks, isEmpty);
  });
}
