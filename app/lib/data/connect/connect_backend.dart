import '../backend.dart';
import '../models.dart';
import 'connect_controller.dart';
import 'connect_wire.dart';
import 'forwarding_backend.dart';

/// The backend the screens use: this device's own, except that while another device of the person plays, what the screens
/// show is that device's, and the commands that steer the player go to it (see [ConnectController]). Everything else is the
/// own backend's, the library, the search, the settings of this device.
class ConnectBackend extends ForwardingBackend {
  ConnectBackend(super.inner, this.connect);

  final ConnectController connect;

  @override
  Stream<BackendEvent> get events => connect.events;

  /// Does [command] on the device that plays when this one controls it, else [own].
  Future<void> _steer(RemoteCommand command, Future<void> Function() own) => connect.send(command) ? Future.value() : own();

  @override
  Future<void> play() => _steer(const RemoteCommand('play'), inner.play);

  @override
  Future<void> pause() => _steer(const RemoteCommand('pause'), inner.pause);

  @override
  Future<void> next() => _steer(const RemoteCommand('next'), inner.next);

  @override
  Future<void> prev() => _steer(const RemoteCommand('prev'), inner.prev);

  @override
  Future<void> seek(int positionMs) => _steer(RemoteCommand('seek', {'ms': positionMs}), () => inner.seek(positionMs));

  @override
  Future<void> jump(String itemId) => _steer(RemoteCommand('jump', {'id': itemId}), () => inner.jump(itemId));

  @override
  Future<void> setVolume(double level) => _steer(RemoteCommand('volume', {'level': level}), () => inner.setVolume(level));

  @override
  Future<void> add(Track track, {bool playNext = false, String source = ListenSource.chosen}) => _steer(
    RemoteCommand('add', {'track': track.toMap(), 'next': playNext, 'source': source}),
    () => inner.add(track, playNext: playNext, source: source),
  );

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false, bool queued = true, String source = ListenSource.chosen}) => _steer(
    RemoteCommand('addMany', {'tracks': [for (final t in tracks) t.toMap()], 'next': playNext, 'queued': queued, 'source': source}),
    () => inner.addMany(tracks, playNext: playNext, queued: queued, source: source),
  );

  @override
  Future<void> playList(List<Track> tracks, {int start = 0, String? label, String source = ListenSource.chosen}) => _steer(
    RemoteCommand('playList', {'tracks': [for (final t in tracks) t.toMap()], 'start': start, 'label': ?label, 'source': source}),
    () => inner.playList(tracks, start: start, label: label, source: source),
  );

  @override
  Future<void> setRepeat(Repeat mode) => _steer(RemoteCommand('repeat', {'mode': mode.name}), () => inner.setRepeat(mode));

  @override
  Future<void> remove(String itemId) => _steer(RemoteCommand('remove', {'id': itemId}), () => inner.remove(itemId));

  @override
  Future<void> swap(String itemId, Track track) =>
      _steer(RemoteCommand('swap', {'id': itemId, 'track': track.toMap()}), () => inner.swap(itemId, track));

  @override
  Future<void> move(String itemId, int toIndex, {bool? queued}) =>
      _steer(RemoteCommand('move', {'id': itemId, 'to': toIndex, 'queued': ?queued}), () => inner.move(itemId, toIndex, queued: queued));

  @override
  Future<void> clear() => _steer(const RemoteCommand('clear'), inner.clear);

  @override
  Future<void> clearQueued() => _steer(const RemoteCommand('clearQueued'), inner.clearQueued);

  @override
  Future<void> shuffle() => _steer(const RemoteCommand('shuffle'), inner.shuffle);

  @override
  Future<void> setShuffle(bool on) => _steer(RemoteCommand('setShuffle', {'on': on}), () => inner.setShuffle(on));

  @override
  Future<void> fillRadio(String videoId) => _steer(RemoteCommand('radio', {'videoId': videoId}), () => inner.fillRadio(videoId));

  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) =>
      _steer(RemoteCommand('sleep', {'mode': mode.name, 'minutes': minutes}), () => inner.setSleep(mode, minutes: minutes));

  @override
  Future<void> setPlaybackSpeed(double speed) => _steer(RemoteCommand('speed', {'speed': speed}), () => inner.setPlaybackSpeed(speed));

  @override
  Future<void> setVideoMode(bool on) => _steer(RemoteCommand('video', {'on': on}), () => inner.setVideoMode(on));
}
