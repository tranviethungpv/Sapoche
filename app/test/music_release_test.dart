import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_controller.dart';
import 'package:sapoche/data/music_models.dart';

import 'fake_backend.dart';

void main() {
  const audio = Track(
    videoId: 'audio',
    title: 'Todo Lo Fue',
    artist: 'Lenin Ramirez',
    durMs: 200000,
    thumb: 'https://img/album.jpg',
  );
  const video = MusicTrack(
    videoId: 'video',
    title: 'Todo Lo Fue (Video Oficial)',
    artist: 'Lenin Ramirez',
    durMs: 200000,
    thumb: 'https://img/still.jpg',
  );

  test('going back to the audio release of a video needs no search: it was where the video came from', () async {
    final backend = FakeBackend()..videoSearchResult = [video];
    final music = MusicController(backend);
    expect(music.audioOf(video), isNull);

    final found = await music.otherRelease(audio, video: true);
    expect(found?.videoId, 'video');
    final searches = backend.calls.where((c) => c.startsWith('musicSearch')).length;

    final back = await music.otherRelease(video, video: false);
    expect(back?.videoId, 'audio');
    expect(back?.thumb, 'https://img/album.jpg', reason: 'the cover of the album, not a still of the video');
    expect(backend.calls.where((c) => c.startsWith('musicSearch')).length, searches);
  });

  test('a video that was not reached from its audio release is looked up as before', () async {
    final backend = FakeBackend()
      ..songSearchResult = [
        const MusicTrack(
          videoId: 'album',
          title: 'Todo Lo Fue',
          artist: 'Lenin Ramirez',
          durMs: 200000,
          isSong: true,
        ),
      ];
    final music = MusicController(backend);
    final back = await music.otherRelease(video, video: false);
    expect(back?.videoId, 'album');
    expect(backend.calls.where((c) => c.startsWith('musicSearch')), isNotEmpty);
  });
}
