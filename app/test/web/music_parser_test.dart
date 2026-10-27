import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/music_client.dart';

// The Dart readers against the answers YouTube Music really gave (cut short), the same fixtures Kotlin and Swift read.
// Ported from MusicParserTest.kt; a change of shape on YouTube's side shows up in all three.

String fixture(String name) =>
    File('../native/core/src/test/resources/music/$name.json').readAsStringSync();

MusicClient client(Map<String, String> answers) =>
    MusicClient((endpoint, _) async => fixture(answers[endpoint]!));

/// A client that keeps the bodies it was asked with.
(MusicClient, List<String>) recording(String answer) {
  final asked = <String>[];
  return (
    MusicClient((_, body) async {
      asked.add(body);
      return fixture(answer);
    }),
    asked,
  );
}

void main() {
  test('the radio of a song starts with it and knows it is a song', () async {
    final next = await client({'next': 'next_song'}).watchNext('lYBUbBu4W08');
    final first = next.tracks.first;
    expect(first.videoId, 'lYBUbBu4W08');
    expect(first.title, 'Never Gonna Give You Up');
    expect(first.artist, 'Rick Astley');
    expect(first.artistId, 'UCwZEU0wAwIyZb4x5G_KJp2w');
    expect(first.album, 'Whenever You Need Somebody');
    expect(first.year, '1987');
    expect(first.durMs, 214000);
    expect(first.stats, isNull);
    expect(first.isSong, isTrue);
    expect(next.tracks.skip(1).every((t) => t.isSong), isTrue, reason: 'the radio of a song is made of songs');
    expect(next.lyricsId, isNotNull);
    expect(next.relatedId, isNotNull);
  });

  test('the radio of a video is made of videos', () async {
    final next = await client({'next': 'next_video'}).watchNext('dQw4w9WgXcQ');
    final first = next.tracks.first;
    expect(first.videoId, 'dQw4w9WgXcQ');
    expect(first.isSong, isFalse);
    expect(first.artist, 'Rick Astley', reason: 'the views and likes that follow are not part of the artist');
    expect(first.album, isNull);
    expect(first.year, isNull);
    expect(first.stats, '1.8B views · 19M likes');
  });

  test('a cover is asked for at a size fit for the player', () async {
    final first = (await client({'next': 'next_song'}).watchNext('lYBUbBu4W08')).tracks.first;
    expect(first.thumb, contains('=w544-h544'));
  });

  test('the related page has songs, other performances, artists and playlists', () async {
    final related = await client({'browse': 'related'}).related('MPTRt_x');
    expect(related.more, isNotEmpty);
    expect(related.more.first.videoId, 'QAo_Ycocl1E');
    expect(related.artists, isNotEmpty);
    expect(related.artists.first.id, startsWith('UC'));
    expect(related.playlists, isNotEmpty);
    expect(related.otherPerformances, isNotEmpty);
    expect(related.about, startsWith('Richard Paul Astley'));
  });

  test('lyrics come as plain text', () async {
    final words = await client({'browse': 'lyrics'}).lyrics('MPLYt_x');
    expect(words, startsWith("We're no strangers to love"));
  });

  test('an artist has a picture, a bio, top songs and releases', () async {
    final artist = await client({'browse': 'artist'}).artist('UCwZEU0wAwIyZb4x5G_KJp2w');
    expect(artist.name, 'Rick Astley');
    expect(artist.description, startsWith('Richard Paul Astley'));
    expect(artist.subscribers?.split(' ').first, '4.55M');
    expect(artist.thumb, isNotNull);
    expect(artist.topSongs, isNotEmpty);
    expect(artist.albums, isNotEmpty);
    expect(artist.albums.every((a) => a.id.startsWith('MPRE')), isTrue);
    expect(artist.singles, isNotEmpty);
    expect(artist.similar, isNotEmpty);
  });

  test('an artist has videos and playlists too, and says where all of the top songs are', () async {
    final page = await client({'browse': 'artist_full'}).artist('UC3muIvzjhubNpJ4Pn_0kCQw');
    expect(page.topSongsId, 'OLAK5uy_kq6u7GZbsa9TKcZQc6HQWPsKsFjQenbmA');
    expect(page.similar, isNotEmpty, reason: 'fans might also like');
    final videos = page.shelves.firstWhere((s) => s.title == 'Videos').tracks.first;
    expect(videos.videoId, 'FN7ALfpGxiI');
    expect(videos.title, 'Nơi này có anh');
    expect(videos.artist, 'Sơn Tùng M-TP');
    expect(videos.stats, '461M views');
    expect(videos.isSong, isFalse);
    expect(page.shelves.any((s) => s.title == 'Live performances'), isTrue);
    expect(
      page.shelves.where((s) => s.title == 'Albums' || s.title == 'Fans might also like'),
      isEmpty,
      reason: 'those have places of their own',
    );
  });

  test('a profile has videos and playlists and no songs of its own', () async {
    final page = await client({'browse': 'profile'}).artist('UC3KdrjbFKLRbobhTLIJPQHQ');
    expect(page.name, 'Tran Nam SKY');
    expect(page.subscribers, '1.91K');
    expect(page.topSongs, isEmpty);
    expect(page.albums, isEmpty);
    expect(page.shelves.map((s) => s.title), ['Videos', 'Playlists']);
    expect(page.shelves.last.playlists, isNotEmpty);
  });

  test('an album has its facts, its songs with the artist filled in and rows to go on to', () async {
    final (music, asked) = recording('album');
    final page = await music.collection('MPREb_rL78Ovsej32');
    expect(asked.single, contains('browseId":"MPREb_rL78Ovsej32"'), reason: 'an album is asked for by its own id');
    expect(page.title, 'm-tp M-TP');
    expect(page.kind, 'Album');
    expect(page.year, '2017');
    expect(page.owner, 'Sơn Tùng M-TP');
    expect(page.ownerId, 'UC3muIvzjhubNpJ4Pn_0kCQw');
    expect(page.stats, ['18 songs', '1 hour, 13 minutes']);
    expect(page.description, isNotNull);
    expect(page.thumb, isNotNull);
    expect(page.more, isNull, reason: 'an album comes whole');
    final first = page.tracks.first;
    expect(first.videoId, 'JQwLF3fsGY0');
    expect(first.title, 'Cơn Mưa Ngang Qua');
    expect(first.artist, 'Sơn Tùng M-TP');
    expect(first.artistId, 'UC3muIvzjhubNpJ4Pn_0kCQw');
    expect(first.album, 'm-tp M-TP');
    expect(first.albumId, 'MPREb_rL78Ovsej32');
    expect(first.durMs, 235000);
    expect(first.isSong, isTrue);
    expect(first.thumb, page.thumb, reason: 'the rows of an album have no picture, so they take the cover of the album');
    expect(page.shelves.first.albums, isNotEmpty);
  });

  test('a playlist is asked for by its id with VL in front, and says who made it', () async {
    final (music, asked) = recording('playlist');
    final page = await music.collection('PLrALqIYcGkySSOHxefqyordgqMgiQHW8P');
    expect(asked.single, contains('browseId":"VLPLrALqIYcGkySSOHxefqyordgqMgiQHW8P"'));
    expect(page.kind, 'Playlist');
    expect(page.year, '2026');
    expect(page.owner, 'Sensual Musique');
    expect(page.stats, ['5M views', '1,818 tracks', '155+ hours']);
    expect(page.tracks.first.title, "The kid in blue, Alberto Ciccarini - Even If You Don't Call (Lyrics)");
    expect(page.tracks.first.artist, 'Sensual Musique');
    expect(page.tracks.first.isSong, isFalse);
    expect(page.tracks.first.album, isNull, reason: 'a playlist does not say which album its songs are on');
    expect(page.more, isNotNull, reason: 'a playlist of 1,818 songs comes a hundred at a time');
  });

  test('the next songs of a playlist come with where the ones after them are', () async {
    final (music, asked) = recording('playlist_more');
    final next = await music.more('TOKEN');
    expect(asked.single, contains('continuation":"TOKEN"'));
    expect(next.tracks.length, 5);
    expect(next.more, isNotNull);
  });

  test('a podcast show lists its episodes, whose rows are not those of songs', () async {
    final (music, asked) = recording('podcast_show');
    final page = await music.collection('MPSPPLycTNLUo2y2EAKEhVfxB9gYo6r0OTMgM0');
    expect(asked.single, contains('browseId":"MPSPPLycTNLUo2y2EAKEhVfxB9gYo6r0OTMgM0"'), reason: 'a show is browsed as it is, without VL');
    expect(page.title, 'InnerFrench Podcast');
    expect(page.tracks.length, 3);
    final first = page.tracks.first;
    expect(first.videoId, 'idcUTDJWCEk');
    expect(first.title, 'E200 Toutes les bonnes choses ont une fin');
    expect(first.artist, 'InnerFrench Podcast', reason: 'the row does not say the show, the page does');
    expect(first.durMs, 3660000, reason: '1 hr 1 min');
    expect(page.tracks[1].durMs, 29 * 60 * 1000);
    expect(first.thumb, isNotNull);
    expect(page.more, isNotNull, reason: 'a show comes a hundred episodes at a time');
  });

  test('the next episodes of a show come with where the ones after them are', () async {
    final (music, _) = recording('podcast_more');
    final next = await music.more('TOKEN');
    expect(next.tracks.length, 3);
    expect(next.tracks.every((t) => t.videoId.length == 11 && t.title.isNotEmpty && t.durMs > 0), isTrue);
    expect(next.more, isNotNull);
  });

  test('a search lists what YouTube Music finds, a top result and the filters on offer', () async {
    final page = await client({'search': 'search_top_song'}).searchPage('never gonna give you up', null);
    // YouTube puts first the kind that suits the search best, so the order is its own
    expect(page.chips.first.label, 'Videos');
    expect(
      page.chips.map((c) => c.label).toSet(),
      {'Artists', 'Albums', 'Songs', 'Videos', 'Community playlists', 'Featured playlists', 'Profiles', 'Episodes', 'Podcasts'},
    );
    // The tail of the code changes with the search, so only its start is the same
    expect(page.chips.firstWhere((c) => c.label == 'Songs').params, startsWith('EgWKAQII'));
    final top = page.top!;
    expect(top.kind, 'video');
    expect(top.id, 'dQw4w9WgXcQ');
    expect(top.title, 'Never Gonna Give You Up');
    expect(top.label, 'Video');
    expect(top.track?.artist, 'Rick Astley');
    // The videos listed inside the card of the top result are not repeated: the list starts after them
    expect(page.items.first.kind, 'song');
    final song = page.items.first;
    expect(song.id, 'lYBUbBu4W08');
    expect(song.label, 'Song');
    expect(song.track?.artist, 'Rick Astley', reason: 'the label is not the artist');
    expect((song.track as dynamic).isSong, isTrue);
    final single = page.items.firstWhere((i) => i.kind == 'album');
    expect(single.id, 'MPREb_noEixV4hNb8');
    expect(single.label, 'Single');
    expect(single.subtitle, 'Caleb Hyles · 2023');
  });

  test('the top result of a search can be an artist', () async {
    final top = (await client({'search': 'search_top_artist'}).searchPage('taylor swift', null)).top!;
    expect(top.kind, 'artist');
    expect(top.id, 'UCPC0L1d253x-KuMNwa05TpA');
    expect(top.title, 'Taylor Swift');
    expect(top.subtitle, '444M monthly audience');
  });

  test('a search for one kind sends its filter and gives that kind', () async {
    final (music, asked) = recording('search_artists');
    final page = await music.searchPage('son tung mtp', 'FILTER');
    expect(asked.single, contains('params":"FILTER"'));
    expect(page.top, isNull);
    expect(page.items.every((i) => i.kind == 'artist'), isTrue);
    final first = page.items.first;
    expect(first.id, 'UC3muIvzjhubNpJ4Pn_0kCQw');
    expect(first.title, 'Sơn Tùng M-TP');
    expect(first.subtitle, '10.8M monthly audience');
    expect(first.thumb, isNotNull);
  });

  test('without a filter the search is not sent one', () async {
    final (music, asked) = recording('search_top_song');
    await music.searchPage('x', null);
    expect(asked.single, isNot(contains('params')));
  });

  test('albums, playlists, profiles and episodes each open or play what they are', () async {
    final albums = (await client({'search': 'search_albums'}).searchPage('q', 'A')).items;
    expect(albums.every((i) => i.kind == 'album' && i.id.startsWith('MPRE')), isTrue);
    expect(albums.first.title, 'Em Của Ngày Hôm Qua');
    expect(albums.first.label, 'Single');
    expect(albums.first.subtitle, 'Sơn Tùng M-TP · 2014');

    final playlists = await client({'search': 'search_playlists'}).searchPage('q', 'P');
    final list = playlists.items.first;
    expect(list.kind, 'playlist');
    expect(list.id, 'PL0NlNYU99BSMfNcGaEWqBWAh7vOtSzUid', reason: 'the VL of the page is not part of the id of the playlist');
    expect(list.subtitle, 'Mùa Đi Ngang Phố · 291K views');
    expect(playlists.more, isNotNull, reason: 'there are more playlists to ask for');

    final profile = (await client({'search': 'search_profiles'}).searchPage('q', 'P')).items.first;
    expect(profile.kind, 'profile');
    expect(profile.id, 'UC3KdrjbFKLRbobhTLIJPQHQ');
    expect(profile.subtitle, '@trannam_sky');

    final episode = (await client({'search': 'search_episodes'}).searchPage('q', 'E')).items.first;
    expect(episode.kind, 'episode');
    expect(episode.id, 'elsqDQZDuMA');
    expect(episode.subtitle, startsWith('Sep 6'));
    expect(episode.track!.artist.isNotEmpty && !episode.track!.artist.startsWith('Sep'), isTrue, reason: 'the show, not the date');
  });

  test('the results after the first ones come with where the ones after them are', () async {
    final (music, asked) = recording('search_more');
    final next = await music.searchMore('TOKEN');
    expect(asked.single, contains('continuation":"TOKEN"'));
    expect(next.items, isNotEmpty);
    expect(next.chips, isEmpty);
    expect(next.top, isNull);
  });

  test('a search for songs gives songs and one for videos gives videos', () async {
    final songs = await client({'search': 'search_songs'}).searchSongs('chung ta cua hien tai');
    expect(songs.first.title, 'Chúng Ta Của Hiện Tại');
    expect(songs.first.artist, 'Sơn Tùng M-TP');
    expect(songs.first.durMs, 302000);
    expect(songs.every((t) => t.isSong), isTrue);

    final videos = await client({'search': 'search_videos'}).searchVideos('chung ta cua hien tai');
    expect(videos, isNotEmpty);
    expect(videos.where((t) => t.isSong), isEmpty);
    expect(videos.every((t) => t.durMs > 0), isTrue);
  });

  test('the home page has shelves of songs or playlists', () async {
    final shelves = await client({'browse': 'home'}).trending();
    expect(shelves, isNotEmpty);
    expect(shelves.every((s) => s.title.trim().isNotEmpty && (s.tracks.isNotEmpty || s.playlists.isNotEmpty)), isTrue);
    expect(shelves.expand((s) => s.playlists).every((p) => p.id.trim().isNotEmpty), isTrue);
  });

  test('the home page offers moods, each with what asks for it', () async {
    final home = await client({'browse': 'home_chips'}).home();
    expect(home.chips.length, greaterThanOrEqualTo(5));
    expect(home.chips.any((c) => c.label == 'Relax'), isTrue);
    expect(home.chips.every((c) => c.label.trim().isNotEmpty && c.params.trim().isNotEmpty), isTrue);
    expect(home.chips.map((c) => c.params).toSet().length, home.chips.length, reason: 'every mood asks for its own');
    expect(home.shelves.isNotEmpty && home.shelves.every((s) => s.title.trim().isNotEmpty), isTrue);
  });

  test('a mood answers with shelves of playlists', () async {
    final (music, bodies) = recording('mood');
    final mood = await music.home('en', 'ggM8abc');
    expect(bodies.single, contains('"params":"ggM8abc"'));
    expect(mood.shelves, isNotEmpty);
    expect(mood.shelves.expand((s) => s.playlists), isNotEmpty, reason: 'a mood is a set of playlists');
    expect(mood.shelves.expand((s) => s.playlists).every((p) => p.id.trim().isNotEmpty && p.title.trim().isNotEmpty), isTrue);
    // Asked for without a mood, the answer carries no params
    final (plain, plainBodies) = recording('home_chips');
    await plain.home();
    expect(plainBodies.single, isNot(contains('params')));
  });

  test('the charts hold playlists and the artists played most', () async {
    final shelves = await client({'browse': 'charts'}).charts();
    expect(shelves.any((s) => s.playlists.isNotEmpty), isTrue);
    final artists = shelves.expand((s) => s.artists).toList();
    expect(artists, isNotEmpty);
    expect(artists.every((a) => a.id.startsWith('UC') && a.name.trim().isNotEmpty), isTrue);
  });

  test('an answer of a shape that is not known gives nothing instead of failing', () async {
    final unknown = MusicClient((_, _) async => '{"unexpected":[1,2,{"a":null}]}');
    expect((await unknown.watchNext('x')).tracks, isEmpty);
    expect(await unknown.lyrics('x'), isNull);
    expect(await unknown.searchSongs('x'), isEmpty);
    expect((await unknown.artist('UC')).name, '');
    expect(await unknown.trending(), isEmpty);
    final home = await unknown.home();
    expect(home.chips, isEmpty);
    expect(home.shelves, isEmpty);
    expect(await unknown.charts(), isEmpty);
  });

  test('the other release is read when YouTube names it', () async {
    String row(String id, String title, String length, String type) => '''
      {"videoId":"$id","title":{"runs":[{"text":"$title"}]},"longBylineText":{"runs":[{"text":"A"}]},
       "lengthText":{"runs":[{"text":"$length"}]},
       "navigationEndpoint":{"watchEndpoint":{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"$type"}}}}}
    ''';
    final answer = '''
      {"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[
        {"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[
          {"playlistPanelVideoWrapperRenderer":{
            "primaryRenderer":{"playlistPanelVideoRenderer":${row('song1', 'T', '3:00', 'MUSIC_VIDEO_TYPE_ATV')}},
            "counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":${row('clip1', 'T (Official Video)', '3:20', 'MUSIC_VIDEO_TYPE_OMV')}}}]}}
        ]}}}}}}
      ]}}}}}
    ''';
    // The app does not show the other release, so the song alone is what is read
    final track = (await MusicClient((_, _) async => answer).watchNext('song1')).tracks.single;
    expect(track.videoId, 'song1');
    expect(track.isSong, isTrue);
    expect(track.durMs, 180000);
  });

  test('only the home page is asked for in the language of the person, everything else in English', () async {
    final bodies = <String>[];
    final music = MusicClient((_, body) async {
      bodies.add(body);
      return '{}';
    }, region: () => 'VN');
    await music.watchNext('x');
    await music.lyrics('x');
    await music.searchSongs('x');
    await music.trending('vi');
    String? field(String body, String name) => RegExp('"$name":"(\\w+)"').firstMatch(body)?.group(1);
    // The readers find lyrics and related songs by the English names of their tabs, so these must not change
    expect(bodies.take(bodies.length - 1).every((b) => field(b, 'hl') == 'en'), isTrue, reason: '$bodies');
    expect(field(bodies.last, 'hl'), 'vi');
    // The country only decides what is shown first, never the words
    expect(bodies.every((b) => field(b, 'gl') == 'VN'), isTrue);
  });

  test('a missing country falls back to the United States', () async {
    var body = '';
    await MusicClient((_, sent) async {
      body = sent;
      return '{}';
    }, region: () => '').searchVideos('x');
    expect(jsonDecode(body)['context']['client']['gl'], 'US');
  });

  test('the completions of a search are the words that would be searched for', () async {
    final (music, asked) = recording('suggestions');
    final found = await music.suggestions('son tung');
    expect(asked.single, contains('"input":"son tung"'));
    expect(found.first, 'sơn tùng m-tp');
    expect(found, contains('son tung mtp'));
    expect(found.toSet().length, found.length);
  });
}
