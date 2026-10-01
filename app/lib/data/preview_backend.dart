import 'dart:async';

import 'backend.dart';
import 'models.dart';
import 'music_models.dart';

/// Stands in for the native side on a platform that has none yet (iOS): the screens open, commands do nothing,
/// lists come back empty and what needs the network throws. Goes away once iOS gets a player of its own.
class PreviewBackend implements Backend {
  final _events = StreamController<BackendEvent>.broadcast();

  static BackendException _unavailable() =>
      BackendException('unavailable', 'Not available on this platform yet');

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Future<Profile> profile() async =>
      const Profile(name: 'iPhone', device: 'iPhone');
  @override
  Future<String> createRoom(String name) async => throw _unavailable();
  @override
  Future<void> join(String code, String name) async => throw _unavailable();
  @override
  Future<void> leave() async {}

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> next() async {}
  @override
  Future<void> prev() async {}
  @override
  Future<void> seek(int positionMs) async {}
  @override
  Future<void> jump(String itemId) async {}
  @override
  Future<void> setSolo(bool on) async {}
  @override
  Future<void> keepPlaying() async {}

  @override
  Future<void> add(Track track, {bool playNext = false}) async {}
  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) async {}
  @override
  Future<void> setRepeat(Repeat mode) async {}
  @override
  Future<void> remove(String itemId) async {}
  @override
  Future<void> swap(String itemId, Track track) async {}
  @override
  Future<void> move(String itemId, int toIndex) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<void> shuffle() async {}
  @override
  Future<void> fillRadio(String videoId) async {}

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false}) async =>
      throw _unavailable();
  @override
  Future<List<PlaylistRef>> searchPlaylists(String query) async =>
      throw _unavailable();
  @override
  Future<LinkResult?> lookup(String text) async => null;

  @override
  Future<void> setVideoMode(bool on) async {}
  @override
  Future<void> setVideoVisible(bool visible) async {}
  @override
  Future<int> videoSurface() async => throw _unavailable();
  @override
  Future<void> setVideoQuality(int height) async {}

  @override
  Future<RoomInfo?> roomInfo(String code) async => null;
  @override
  Future<void> kick(String memberId) async {}
  @override
  Future<void> setRoomName(String name) async {}
  @override
  Future<void> setGuestControl(GuestControl mode) async {}
  @override
  Future<void> rename(String name) async {}
  @override
  Future<void> share(String text) async {}

  @override
  Future<List<Track>> liked() async => const [];
  @override
  Future<List<HistoryEntry>> recent() async => const [];
  @override
  Future<void> setLiked(Track track, bool liked) async {}
  @override
  Future<void> clearHistory() async {}

  @override
  Future<List<DownloadEntry>> downloads() async => const [];
  @override
  Future<bool> download(
    List<Track> tracks, {
    bool allowMetered = false,
  }) async => false;
  @override
  Future<void> removeDownload(String videoId) async {}
  @override
  Future<void> clearDownloads() async {}
  @override
  Future<StorageInfo> storage() async => const StorageInfo();
  @override
  Future<void> clearPlayCache() async {}
  @override
  Future<void> setCacheLimit(int mb) async {}
  @override
  Future<void> setAutoDownload(bool on) async {}

  @override
  Future<List<Track>> forYou() async => const [];
  @override
  Future<List<Track>> refreshSuggestions() async => const [];
  @override
  Future<List<String>> suggest(String query) async => const [];
  @override
  Future<void> setAutoplay(bool on) async {}

  @override
  Future<List<SavedPlaylist>> playlists() async => const [];
  @override
  Future<List<Track>> playlistTracks(int id) async => const [];
  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async =>
      throw _unavailable();
  @override
  Future<void> renamePlaylist(int id, String name) async {}
  @override
  Future<void> deletePlaylist(int id) async {}
  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async => 0;
  @override
  Future<void> removeFromPlaylist(int id, String videoId) async {}
  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) async {}

  @override
  Future<BackupCounts?> exportBackup() async => null;
  @override
  Future<BackupCounts?> importBackup() async => null;
  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) async {}

  @override
  Future<SongRadio> musicNext(String videoId) async => throw _unavailable();
  @override
  Future<RelatedPage> musicRelated(String videoId) async =>
      throw _unavailable();
  @override
  Future<ArtistPage> musicArtist(String artistId) async =>
      throw _unavailable();
  @override
  Future<List<MusicShelf>> musicTrending() async => const [];
  @override
  Future<List<MusicTrack>> musicSearch(
    String query, {
    required bool songs,
  }) async => throw _unavailable();
  @override
  Future<List<SeedList>> seedLists() async => const [];
  @override
  Future<Lyrics?> lyrics(Track track) async => null;

  @override
  Future<void> setTrim(int ms) async {}
  @override
  Future<List<String>> log() async => const [];
  @override
  Future<void> setSmooth(bool on) async {}
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
