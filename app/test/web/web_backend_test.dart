import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/library_store.dart';
import 'package:sapoche/data/web/web_backend.dart';

import 'group_session_test.dart' show FakePlayer;

String fixture(String name) =>
    File('../native/core/src/test/resources/music/$name.json').readAsStringSync();

/// An answer of the server; as bytes, since the fixtures hold letters that Latin-1 does not.
http.Response ok(String body) => http.Response.bytes(utf8.encode(body), 200);

/// A [WebBackend] whose server is [handler]; it keeps the requests it was sent.
Future<(WebBackend, List<http.Request>)> backendWith(
  http.Response Function(http.Request request) handler, {
  Map<String, Object> prefs = const {},
  String? invite,
  MediaControls? media,
  int Function()? nowMs,
  LibraryStore? library,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final seen = <http.Request>[];
  final backend = WebBackend(
    player: FakePlayer(),
    prefs: await SharedPreferences.getInstance(),
    defaultServer: 'https://sapoche.example',
    invite: invite,
    media: media,
    nowMs: nowMs,
    library: library,
    client: MockClient((request) async {
      seen.add(request);
      return handler(request);
    }),
  );
  return (backend, seen);
}

class _Media implements MediaControls {
  final shown = <(String?, String?, bool)>[];
  void Function()? pause;

  @override
  void update({String? title, String? artist, String? artwork, required bool playing}) =>
      shown.add((title, artist, playing));

  @override
  void bind({
    required void Function() play,
    required void Function() pause,
    required void Function() next,
    required void Function() prev,
    required void Function(int positionMs) seek,
  }) => this.pause = pause;
}

void main() {
  test('the server is the page itself, and only the key is left for the person to give', () async {
    final (backend, _) = await backendWith((_) => http.Response('', 404));
    var profile = await backend.profile();
    expect(profile.server, 'https://sapoche.example');
    expect(profile.configured, isTrue);
    expect(profile.hasKey, isFalse);
    await backend.configure(key: ' secret ');
    profile = await backend.profile();
    expect(profile.hasKey, isTrue);
    await backend.configure(server: 'other.example/');
    expect((await backend.profile()).server, 'https://other.example');
  });

  test('the link to share carries the key, and there is none to share without one', () async {
    var (backend, _) = await backendWith((_) => http.Response('', 404));
    expect(await backend.setupLink(), isNull);
    (backend, _) = await backendWith((_) => http.Response('', 404), prefs: {'web.key': 'a b+c'});
    expect(await backend.setupLink(), 'https://sapoche.example/#key=a%20b%2Bc');
  });

  test('without a key a room cannot be made, and the screen is told to ask for it', () async {
    final (backend, seen) = await backendWith((_) => http.Response('{}', 200));
    await expectLater(
      backend.createRoom('Me'),
      throwsA(isA<BackendException>().having((e) => e.code, 'code', 'not_configured')),
    );
    expect(seen, isEmpty);
  });

  test('a room is asked for with the key, and a refused key is told as such', () async {
    final (backend, seen) = await backendWith(
      (r) => http.Response('', 401),
      prefs: {'web.key': 'wrong'},
    );
    await expectLater(
      backend.createRoom('Me'),
      throwsA(isA<BackendException>().having((e) => e.message, 'message', contains('key'))),
    );
    expect(seen.single.url.path, '/rooms');
    expect(seen.single.headers['X-Sapoche-Key'], 'wrong');
  });

  test('a search asks YouTube Music through the server, with the key, and gives songs', () async {
    final (backend, seen) = await backendWith(
      (_) => ok(fixture('search_songs')),
      prefs: {'web.key': 'k'},
    );
    final found = await backend.search('chung ta cua hien tai', songsOnly: true);
    expect(seen.first.url.toString(), 'https://sapoche.example/yt/search');
    expect(seen.first.headers['X-Sapoche-Key'], 'k');
    final sent = jsonDecode(seen.first.body) as Map<String, dynamic>;
    expect(sent['query'], 'chung ta cua hien tai');
    expect(sent['params'], 'EgWKAQIIAWoKEAkQBRAKEAMQBA==');
    expect(found, isNotEmpty);
    expect(found.first.title, 'Chúng Ta Của Hiện Tại');
    expect(found.length, lessThanOrEqualTo(20));
  });

  test('a search with nothing in it asks nothing', () async {
    final (backend, seen) = await backendWith((_) => http.Response('{}', 200));
    expect(await backend.search('   '), isEmpty);
    expect(seen, isEmpty);
  });

  test('the same page is not asked for twice', () async {
    final (backend, seen) = await backendWith(
      (_) => ok(fixture('artist')),
      prefs: {'web.key': 'k'},
    );
    final first = await backend.musicArtist('UCwZEU0wAwIyZb4x5G_KJp2w');
    final second = await backend.musicArtist('UCwZEU0wAwIyZb4x5G_KJp2w');
    expect(first.name, 'Rick Astley');
    expect(identical(first, second), isTrue);
    expect(seen.length, 1);
  });

  test('a key the server turns down is told once, in words, however many requests it refuses', () async {
    final (backend, _) = await backendWith((_) => http.Response('', 401), prefs: {'web.key': 'old'});
    final errors = <ServerError>[];
    backend.events.listen((e) {
      if (e is ErrorEvent) errors.add(e.error);
    });
    for (var i = 0; i < 3; i++) {
      await expectLater(backend.musicArtist('UC$i'), throwsA(isA<BackendException>()));
    }
    await Future<void>.delayed(Duration.zero);
    expect(errors.map((e) => e.code), ['key_refused']);
  });

  test('YouTube Music saying no is an error the screen can show', () async {
    final (backend, _) = await backendWith((_) => http.Response('no', 502), prefs: {'web.key': 'k'});
    await expectLater(backend.musicArtist('UC'), throwsA(isA<BackendException>()));
  });

  test('the radio of a song says whether it has lyrics and a related page', () async {
    final (backend, _) = await backendWith((_) => ok(fixture('next_song')), prefs: {'web.key': 'k'});
    final radio = await backend.musicNext('lYBUbBu4W08');
    expect(radio.tracks.first.videoId, 'lYBUbBu4W08');
    expect(radio.hasLyrics, isTrue);
    expect(radio.hasRelated, isTrue);
  });

  group('lyrics', () {
    const track = Track(videoId: 'lYBUbBu4W08', title: 'Song', artist: 'Artist', durMs: 213000);
    const timed = '{"duration":213.0,"plainLyrics":"One","syncedLyrics":"[00:01.00] One\\n[00:02.00] Two"}';

    /// The room server answers the pages of YouTube Music; LRCLIB answers with [lrclib].
    http.Response Function(http.Request) answers(http.Response Function() lrclib) => (request) {
      if (request.url.host == 'lrclib.net') return lrclib();
      return ok(fixture(request.url.path.endsWith('/next') ? 'next_song' : 'lyrics'));
    };

    test('run along with the music when LRCLIB has them, and LRCLIB is told only the name and the length', () async {
      final (backend, seen) = await backendWith(answers(() => ok(timed)), prefs: {'web.key': 'k'});
      final lyrics = (await backend.lyrics(track))!;
      expect(lyrics.synced, isTrue);
      expect(lyrics.lines.map((l) => l.text), ['One', 'Two']);
      final asked = seen.firstWhere((r) => r.url.host == 'lrclib.net');
      expect(asked.url.queryParameters, {'track_name': 'Song', 'artist_name': 'Artist', 'duration': '213'});
      expect(asked.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-sapoche-key')), reason: 'the key is for the room server only');
    });

    test('are the plain words of YouTube Music when LRCLIB has none', () async {
      final (backend, _) = await backendWith(answers(() => http.Response('', 404)), prefs: {'web.key': 'k'});
      final lyrics = (await backend.lyrics(track))!;
      expect(lyrics.synced, isFalse);
      expect(lyrics.plain, startsWith("We're no strangers to love"));
    });

    test('are still the plain words when LRCLIB cannot be reached', () async {
      final (backend, _) = await backendWith(answers(() => http.Response('', 503)), prefs: {'web.key': 'k'});
      expect((await backend.lyrics(track))!.plain, startsWith("We're no strangers to love"));
    });

    test('are a failure, not "none", when nobody could be asked', () async {
      final (backend, _) = await backendWith(
        (request) => request.url.host == 'lrclib.net' ? http.Response('', 503) : http.Response('', 502),
        prefs: {'web.key': 'k'},
      );
      await expectLater(backend.lyrics(track), throwsA(isA<Object>()));
    });
  });

  test('commands that only a room understands say there is none', () async {
    final (backend, _) = await backendWith((_) => http.Response('{}', 200));
    await expectLater(
      backend.kick('x'),
      throwsA(isA<BackendException>().having((e) => e.code, 'code', 'no_room')),
    );
  });

  test('a link to a room is offered once, after the first state', () async {
    final (backend, _) = await backendWith((_) => http.Response('{}', 200), invite: 'ABC234');
    final events = <BackendEvent>[];
    backend.events.listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final seen = events.map((e) => e.runtimeType).toList();
    expect(seen.indexOf(StateEvent), lessThan(seen.indexOf(InviteEvent)));
    expect(events.whereType<InviteEvent>().single.code, 'ABC234');
    // A second screen listening later is not offered it again
    backend.events.listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events.whereType<InviteEvent>(), hasLength(1));
  });

  test('the browser outside the page is told what plays, and its buttons work', () async {
    final media = _Media();
    final (backend, _) = await backendWith((_) => http.Response('{}', 200), media: media);
    backend.events.listen((_) {});
    await backend.add(const Track(videoId: 'abc', title: 'Song', artist: 'A', durMs: 200000));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(media.shown.last, ('Song', 'A', true));
    media.pause!();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(media.shown.last.$3, isFalse);
  });

  test('outside a room a song put on the queue plays on this device and the screen is told', () async {
    final (backend, _) = await backendWith((_) => http.Response('{}', 200));
    final events = <BackendEvent>[];
    backend.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<StateEvent>().first.snapshot.room, isNull);

    await backend.add(const Track(videoId: 'abc', title: 'Song', artist: 'A', durMs: 200000));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final state = events.whereType<StateEvent>().last.snapshot;
    expect(state.queue.map((e) => e.videoId), ['abc']);
    expect(state.inRoom, isFalse);
    expect(state.phase, 'paused', reason: 'outside a room the player says whether it plays');
    expect(state.loading, isFalse);
    expect(events.whereType<PositionEvent>().last.position.playing, isTrue);
  });

  test('a song played for half a minute is in the history, once, and the screen is told', () async {
    var clock = 0;
    final library = LibraryStore();
    final (backend, _) = await backendWith((_) => http.Response('{}', 200), nowMs: () => clock, library: library);
    final events = <BackendEvent>[];
    backend.events.listen(events.add);
    await backend.add(const Track(videoId: 'abc', title: 'Song', artist: 'A', durMs: 200000));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await backend.recent(), isEmpty, reason: 'not yet half a minute');
    clock = 31000;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final heard = await backend.recent();
    expect(heard.map((e) => e.track.videoId), ['abc']);
    expect(heard.single.track.title, 'Song');
    expect(events.whereType<LibraryEvent>(), isNotEmpty);
    clock = 90000;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect((await backend.listens()).length, 1, reason: 'a song counts once however long it plays');
  });

  test('liking a song, a playlist of it and the history answer through the same commands as the apps', () async {
    final (backend, _) = await backendWith((_) => http.Response('{}', 200));
    const song = Track(videoId: 'abc', title: 'Song', artist: 'A', durMs: 200000);
    await backend.setLiked(song, true);
    expect((await backend.liked()).map((t) => t.videoId), ['abc']);
    final id = await backend.createPlaylist('Mix', [song]);
    expect((await backend.playlists()).single.count, 1);
    expect((await backend.playlistTracks(id)).single.title, 'Song');
    await backend.setLiked(song, false);
    expect(await backend.liked(), isEmpty);
  });

  test('a browser starts with the cover, and the frame of YouTube is shown when it is asked for', () async {
    final (backend, _) = await backendWith((_) => http.Response('{}', 200));
    final events = <BackendEvent>[];
    backend.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<StateEvent>().last.snapshot.video, isFalse);
    await backend.setVideoMode(true);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<StateEvent>().last.snapshot.video, isTrue);
    await backend.setVideoMode(false);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<StateEvent>().last.snapshot.video, isFalse);
  });
}
