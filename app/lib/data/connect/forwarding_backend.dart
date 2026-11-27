// Written by tool/gen_forwarding_backend.py from `abstract class Backend`: do not edit by hand, run the script again.
import 'dart:typed_data';

import '../../frame_boost.dart';
import '../backend.dart';
import '../chat_media.dart' show PickedPhoto;
import '../models.dart';
import '../music_models.dart';

/// A [Backend] that hands every call to [inner]; [ConnectBackend] changes the few it must.
class ForwardingBackend implements Backend {
  ForwardingBackend(this.inner);

  final Backend inner;

  @override
  Stream<BackendEvent> get events => inner.events;

  @override
  Future<Profile> profile() => inner.profile();

  @override
  Future<void> configure({String? server, String? key}) => inner.configure(server: server, key: key);

  @override
  Future<ServerCheck> checkServer() => inner.checkServer();

  @override
  Future<String?> setupLink() => inner.setupLink();

  @override
  Future<String?> cacheFolder() => inner.cacheFolder();

  @override
  Future<VideoFile> prepareVideo(String path, int maxBytes, {bool mirror = false}) => inner.prepareVideo(path, maxBytes, mirror: mirror);

  @override
  Future<bool> clipboardHasPhotos() => inner.clipboardHasPhotos();

  @override
  Future<List<PickedPhoto>> clipboardPhotos() => inner.clipboardPhotos();

  @override
  Future<String> createRoom(String name) => inner.createRoom(name);

  @override
  Future<void> join(String code, String name) => inner.join(code, name);

  @override
  Future<void> leave() => inner.leave();

  @override
  Future<void> play() => inner.play();

  @override
  Future<void> pause() => inner.pause();

  @override
  Future<void> next() => inner.next();

  @override
  Future<void> prev() => inner.prev();

  @override
  Future<void> seek(int positionMs) => inner.seek(positionMs);

  @override
  Future<void> jump(String itemId) => inner.jump(itemId);

  @override
  Future<void> setSolo(bool on) => inner.setSolo(on);

  @override
  Future<void> pickOutput() => inner.pickOutput();

  @override
  Future<void> setVolume(double level) => inner.setVolume(level);

  @override
  Future<void> setAvatar(String? base64) => inner.setAvatar(base64);

  @override
  Future<bool> sendChat(String text, String cid, {int? reply, ChatQuote? quote, Map<String, Object?>? extra}) => inner.sendChat(text, cid, reply: reply, quote: quote, extra: extra);

  @override
  Future<MediaTickets> mediaTickets(List<int> sizes) => inner.mediaTickets(sizes);

  @override
  Future<bool> uploadMedia(MediaTicket ticket, Uint8List bytes) => inner.uploadMedia(ticket, bytes);

  @override
  Future<Uint8List?> downloadMedia(String room, String m) => inner.downloadMedia(room, m);

  @override
  Future<bool> enableEncryption() => inner.enableEncryption();

  @override
  Future<String?> roomSecret() => inner.roomSecret();

  @override
  Future<bool> setRoomSecret(String room, String secret) => inner.setRoomSecret(room, secret);

  @override
  Future<void> reactChat(int id, Reaction? reaction) => inner.reactChat(id, reaction);

  @override
  Future<bool> loadOlderChat(int before) => inner.loadOlderChat(before);

  @override
  Future<void> readChat(int upTo) => inner.readChat(upTo);

  @override
  Future<void> react(Reaction reaction, int count) => inner.react(reaction, count);

  @override
  Future<void> keepPlaying() => inner.keepPlaying();

  @override
  Future<void> add(Track track, {bool playNext = false, String source = ListenSource.chosen}) => inner.add(track, playNext: playNext, source: source);

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false, bool queued = true, String source = ListenSource.chosen}) => inner.addMany(tracks, playNext: playNext, queued: queued, source: source);

  @override
  Future<void> playList(List<Track> tracks, {int start = 0, String? label, String source = ListenSource.chosen}) => inner.playList(tracks, start: start, label: label, source: source);

  @override
  Future<void> setRepeat(Repeat mode) => inner.setRepeat(mode);

  @override
  Future<QueueHandover?> queueExport() => inner.queueExport();

  @override
  Future<bool> queueImport(String json, {bool play = true}) => inner.queueImport(json, play: play);

  @override
  Future<void> remove(String itemId) => inner.remove(itemId);

  @override
  Future<void> swap(String itemId, Track track) => inner.swap(itemId, track);

  @override
  Future<void> move(String itemId, int toIndex, {bool? queued}) => inner.move(itemId, toIndex, queued: queued);

  @override
  Future<void> clear() => inner.clear();

  @override
  Future<void> clearQueued() => inner.clearQueued();

  @override
  Future<List<Track>> search( String query, { bool songsOnly = false, int? limit, }) => inner.search(query, songsOnly: songsOnly, limit: limit);

  @override
  Future<void> shuffle() => inner.shuffle();

  @override
  Future<void> setShuffle(bool on) => inner.setShuffle(on);

  @override
  Future<void> fillRadio(String videoId) => inner.fillRadio(videoId);

  @override
  Future<void> setVideoMode(bool on) => inner.setVideoMode(on);

  @override
  Future<void> setVideoVisible(bool visible) => inner.setVideoVisible(visible);

  @override
  Future<int> videoSurface() => inner.videoSurface();

  @override
  Future<void> setVideoQuality(int height) => inner.setVideoQuality(height);

  @override
  Future<void> setPlaybackSpeed(double speed) => inner.setPlaybackSpeed(speed);

  @override
  Future<void> setVideoWatching(bool on, {int width = 0, int height = 0}) => inner.setVideoWatching(on, width: width, height: height);

  @override
  Future<bool> pictureInPictureSupported() => inner.pictureInPictureSupported();

  @override
  Future<void> enterPictureInPicture() => inner.enterPictureInPicture();

  @override
  Future<LinkResult?> lookup(String text) => inner.lookup(text);

  @override
  Future<RoomInfo?> roomInfo(String code) => inner.roomInfo(code);

  @override
  Future<void> kick(String memberId) => inner.kick(memberId);

  @override
  Future<void> setRoomName(String name) => inner.setRoomName(name);

  @override
  Future<void> setRoomTheme(String theme, {String? background}) => inner.setRoomTheme(theme, background: background);

  @override
  Future<void> setGuestControl(GuestControl mode) => inner.setGuestControl(mode);

  @override
  Future<void> setRoomAutoplay(bool on) => inner.setRoomAutoplay(on);

  @override
  Future<void> setRoomWaitWeak(bool on) => inner.setRoomWaitWeak(on);

  @override
  Future<void> rename(String name) => inner.rename(name);

  @override
  Future<void> share(String text) => inner.share(text);

  @override
  Future<List<Track>> liked() => inner.liked();

  @override
  Future<List<HistoryEntry>> recent() => inner.recent();

  @override
  Future<List<HistoryEntry>> listens({int limit = 600}) => inner.listens(limit: limit);

  @override
  Future<void> setLiked(Track track, bool liked) => inner.setLiked(track, liked);

  @override
  Future<void> clearHistory() => inner.clearHistory();

  @override
  Future<List<DownloadEntry>> downloads() => inner.downloads();

  @override
  Future<bool> download(List<Track> tracks, {bool allowMetered = false}) => inner.download(tracks, allowMetered: allowMetered);

  @override
  Future<void> removeDownload(String videoId) => inner.removeDownload(videoId);

  @override
  Future<void> clearDownloads() => inner.clearDownloads();

  @override
  Future<void> cancelDownloads() => inner.cancelDownloads();

  @override
  Future<LocalStatus> localStatus() => inner.localStatus();

  @override
  Future<void> setLocalEnabled(bool on) => inner.setLocalEnabled(on);

  @override
  Future<LocalAccess> localAccess() => inner.localAccess();

  @override
  Future<LocalScan> localScan() => inner.localScan();

  @override
  Future<int?> localImport() => inner.localImport();

  @override
  Future<List<LocalSong>> localTracks() => inner.localTracks();

  @override
  Future<Uint8List?> localCover(String videoId) => inner.localCover(videoId);

  @override
  Future<StorageInfo> storage() => inner.storage();

  @override
  Future<void> clearPlayCache() => inner.clearPlayCache();

  @override
  Future<NotificationInfo> notifications() => inner.notifications();

  @override
  Future<NotificationInfo> setNotifications(bool on) => inner.setNotifications(on);

  @override
  Future<void> setNotificationPreview(bool on) => inner.setNotificationPreview(on);

  @override
  Future<void> muteRoomNotifications(String code, int? until) => inner.muteRoomNotifications(code, until);

  @override
  Future<void> setCacheLimit(int mb) => inner.setCacheLimit(mb);

  @override
  Future<void> setAutoDownload(bool on) => inner.setAutoDownload(on);

  @override
  Future<void> setOfflineCellular(bool on) => inner.setOfflineCellular(on);

  @override
  Future<void> setPlaylistOffline(int id, bool on, {bool remove = false}) => inner.setPlaylistOffline(id, on, remove: remove);

  @override
  Future<void> setFolderOffline(int id, bool on, {bool remove = false}) => inner.setFolderOffline(id, on, remove: remove);

  @override
  Future<int> offlineRemovable({int? playlistId, int? folderId}) => inner.offlineRemovable(playlistId: playlistId, folderId: folderId);

  @override
  Future<List<Track>> forYou() => inner.forYou();

  @override
  Future<List<Track>> refreshSuggestions() => inner.refreshSuggestions();

  @override
  Future<List<Track>> discover() => inner.discover();

  @override
  Future<void> tasteMark(String kind, String key, String label, {required bool on}) => inner.tasteMark(kind, key, label, on: on);

  @override
  Future<ContextMix> contextMix() => inner.contextMix();

  @override
  Future<TasteProfile> tasteProfile() => inner.tasteProfile();

  @override
  Future<void> block(Track track, {bool artistOnly = false}) => inner.block(track, artistOnly: artistOnly);

  @override
  Future<void> unblock(BlockedItem item) => inner.unblock(item);

  @override
  Future<List<BlockedItem>> blocked() => inner.blocked();

  @override
  Future<List<String>> suggest(String query) => inner.suggest(query);

  @override
  Future<void> warm(List<String> videoIds) => inner.warm(videoIds);

  @override
  Future<void> setAutoplay(bool on) => inner.setAutoplay(on);

  @override
  Future<void> setShareTaste(bool on) => inner.setShareTaste(on);

  @override
  Future<void> setAudioQuality(AudioQuality quality) => inner.setAudioQuality(quality);

  @override
  Future<void> setNormalizeVolume(bool on) => inner.setNormalizeVolume(on);

  @override
  Future<void> setCrossfade(int seconds) => inner.setCrossfade(seconds);

  @override
  Future<void> setEqualizer(String preset, List<int> gains) => inner.setEqualizer(preset, gains);

  @override
  Future<void> openSystemEqualizer() => inner.openSystemEqualizer();

  @override
  Future<ScrobbleState> scrobbleState({String service = ScrobbleServices.listenBrainz}) => inner.scrobbleState(service: service);

  @override
  Future<ScrobbleState> scrobbleConnect(String token, {String service = ScrobbleServices.listenBrainz}) => inner.scrobbleConnect(token, service: service);

  @override
  Future<ScrobbleState> scrobbleDisconnect({String service = ScrobbleServices.listenBrainz}) => inner.scrobbleDisconnect(service: service);

  @override
  Future<ScrobbleState> scrobbleNowPlaying(bool on, {String service = ScrobbleServices.listenBrainz}) => inner.scrobbleNowPlaying(on, service: service);

  @override
  Future<LastFmBegin> lastfmBegin() => inner.lastfmBegin();

  @override
  Future<List<SavedPlaylist>> playlists() => inner.playlists();

  @override
  Future<List<Track>> playlistTracks(int id) => inner.playlistTracks(id);

  @override
  Future<List<PlaylistFolder>> folders() => inner.folders();

  @override
  Future<int> createFolder(String name) => inner.createFolder(name);

  @override
  Future<void> renameFolder(int id, String name) => inner.renameFolder(id, name);

  @override
  Future<void> deleteFolder(int id) => inner.deleteFolder(id);

  @override
  Future<void> setPlaylistFolder(int id, int? folderId) => inner.setPlaylistFolder(id, folderId);

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) => inner.createPlaylist(name, tracks);

  @override
  Future<void> renamePlaylist(int id, String name) => inner.renamePlaylist(id, name);

  @override
  Future<void> deletePlaylist(int id) => inner.deletePlaylist(id);

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) => inner.addToPlaylist(id, tracks);

  @override
  Future<void> removeFromPlaylist(int id, String videoId) => inner.removeFromPlaylist(id, videoId);

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) => inner.movePlaylistItem(id, videoId, toIndex);

  @override
  Future<BackupCounts?> exportBackup() => inner.exportBackup();

  @override
  Future<BackupCounts?> importBackup() => inner.importBackup();

  @override
  Future<String> librarySnapshot() => inner.librarySnapshot();

  @override
  Future<void> libraryMerge(String json) => inner.libraryMerge(json);

  @override
  Future<String> serverKey() => inner.serverKey();

  @override
  Future<String?> syncKey() => inner.syncKey();

  @override
  Future<void> setSyncKey(String? code) => inner.setSyncKey(code);

  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) => inner.setSleep(mode, minutes: minutes);

  @override
  Future<SongRadio> musicNext(String videoId) => inner.musicNext(videoId);

  @override
  Future<int?> musicViews(String videoId) => inner.musicViews(videoId);

  @override
  Future<RelatedPage> musicRelated(String videoId) => inner.musicRelated(videoId);

  @override
  Future<ArtistPage> musicArtist(String artistId) => inner.musicArtist(artistId);

  @override
  Future<CollectionPage> musicCollection(String id) => inner.musicCollection(id);

  @override
  Future<MoreTracks> musicMore(String token) => inner.musicMore(token);

  @override
  Future<SearchResults> musicSearchPage(String query, {String? params}) => inner.musicSearchPage(query, params: params);

  @override
  Future<SearchResults> musicSearchMore(String token) => inner.musicSearchMore(token);

  @override
  Future<List<MusicShelf>> musicTrending() => inner.musicTrending();

  @override
  Future<MusicHome> musicHome({String? params}) => inner.musicHome(params: params);

  @override
  Future<List<MusicShelf>> musicCharts() => inner.musicCharts();

  @override
  Future<List<MusicTrack>> musicSearch(String query, {required bool songs}) => inner.musicSearch(query, songs: songs);

  @override
  Future<List<SeedList>> seedLists() => inner.seedLists();

  @override
  Future<Lyrics?> lyrics(Track track) => inner.lyrics(track);

  @override
  Future<void> setTrim(int ms) => inner.setTrim(ms);

  @override
  Future<List<String>> log() => inner.log();

  @override
  Future<List<String>> logInfo() => inner.logInfo();

  @override
  Future<void> logMark(String note) => inner.logMark(note);

  @override
  Future<void> logClear() => inner.logClear();

  @override
  Future<void> note(String line) => inner.note(line);

  @override
  Future<void> setDisplayPace(DisplayPace pace) => inner.setDisplayPace(pace);

  @override
  Future<void> setLanguage(String code) => inner.setLanguage(code);

  @override
  Future<void> updateCheck() => inner.updateCheck();

  @override
  Future<bool> updateDownload({bool allowMetered = false}) => inner.updateDownload(allowMetered: allowMetered);

  @override
  Future<bool> updateInstall() => inner.updateInstall();

  @override
  Future<void> updateAllowInstalls() => inner.updateAllowInstalls();

  @override
  Future<void> setAutoUpdate(bool on) => inner.setAutoUpdate(on);
}
