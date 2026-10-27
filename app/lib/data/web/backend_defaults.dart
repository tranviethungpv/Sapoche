import 'dart:typed_data';

import '../../frame_boost.dart';
import '../backend.dart';
import '../models.dart';
import '../music_models.dart';

/// What a browser has no answer for yet, or never will: lists are empty, switches do nothing and what has to return
/// something throws [unsupported]. [WebBackend] overrides what it can do; the rest of this shrinks as the web build grows.
abstract class BackendDefaults implements Backend {
  static BackendException get unsupported =>
      BackendException('unsupported', 'This does not work in a browser yet');

  @override
  Future<String?> setupLink() async => null;

  @override
  Future<String?> cacheFolder() async => null;

  @override
  Future<void> pickOutput() async {}

  @override
  Future<void> setVolume(double level) async {}

  @override
  Future<void> setAvatar(String? base64) async {}

  @override
  Future<void> keepPlaying() async {}

  @override
  Future<void> fillRadio(String videoId) async {}

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> setVideoVisible(bool visible) async {}

  @override
  Future<int> videoSurface() async => throw unsupported;

  @override
  Future<void> setVideoWatching(bool on, {int width = 0, int height = 0}) async {}

  @override
  Future<bool> pictureInPictureSupported() async => false;

  @override
  Future<void> enterPictureInPicture() async {}

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false, int? limit}) async => const [];

  @override
  Future<void> share(String text) async {}

  @override
  Future<List<DownloadEntry>> downloads() async => const [];

  @override
  Future<bool> download(List<Track> tracks, {bool allowMetered = false}) async => false;

  @override
  Future<void> removeDownload(String videoId) async {}

  @override
  Future<void> clearDownloads() async {}

  @override
  Future<LocalStatus> localStatus() async => const LocalStatus(enabled: false);

  @override
  Future<void> setLocalEnabled(bool on) async {}

  @override
  Future<LocalAccess> localAccess() async => LocalAccess.blocked;

  @override
  Future<LocalScan> localScan() async => throw unsupported;

  @override
  Future<int?> localImport() async => null;

  @override
  Future<List<LocalSong>> localTracks() async => const [];

  @override
  Future<Uint8List?> localCover(String videoId) async => null;

  @override
  Future<StorageInfo> storage() async => const StorageInfo();

  @override
  Future<void> clearPlayCache() async {}

  @override
  Future<void> setCacheLimit(int mb) async {}

  @override
  Future<void> setAutoDownload(bool on) async {}

  @override
  Future<void> setAutoplay(bool on) async {}

  @override
  Future<void> setAudioQuality(AudioQuality quality) async {}

  @override
  Future<BackupCounts?> exportBackup() async => null;

  @override
  Future<BackupCounts?> importBackup() async => null;

  @override
  Future<SongRadio> musicNext(String videoId) async => throw unsupported;

  @override
  Future<RelatedPage> musicRelated(String videoId) async => throw unsupported;

  @override
  Future<ArtistPage> musicArtist(String artistId) async => throw unsupported;

  @override
  Future<CollectionPage> musicCollection(String id) async => throw unsupported;

  @override
  Future<MoreTracks> musicMore(String token) async => throw unsupported;

  @override
  Future<SearchResults> musicSearchPage(String query, {String? params}) async => throw unsupported;

  @override
  Future<SearchResults> musicSearchMore(String token) async => throw unsupported;

  @override
  Future<List<MusicShelf>> musicTrending() async => throw unsupported;

  @override
  Future<MusicHome> musicHome({String? params}) async => throw unsupported;

  @override
  Future<List<MusicShelf>> musicCharts() async => throw unsupported;

  @override
  Future<List<MusicTrack>> musicSearch(String query, {required bool songs}) async => throw unsupported;

  @override
  Future<Lyrics?> lyrics(Track track) async => null;

  @override
  Future<void> setTrim(int ms) async {}

  @override
  Future<void> setDisplayPace(DisplayPace pace) async {}

  @override
  Future<void> setLanguage(String code) async {}

  @override
  Future<void> updateCheck() async {}

  @override
  Future<bool> updateDownload({bool allowMetered = false}) async => false;

  @override
  Future<bool> updateInstall() async => false;

  @override
  Future<void> updateAllowInstalls() async {}
}
