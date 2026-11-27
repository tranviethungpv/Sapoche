import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend.dart';
import '../models.dart';
import '../sync/sync_crypto.dart';
import '../web/room_socket.dart';
import 'connect_client.dart';
import 'connect_keys.dart';
import 'connect_wire.dart';

/// Where a device keeps what it must remember between runs (its secret id, its name, what it lets others do).
abstract interface class ConnectStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PrefsConnectStore implements ConnectStore {
  const PrefsConnectStore();

  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString('connect.$key');

  @override
  Future<void> write(String key, String value) async => (await SharedPreferences.getInstance()).setString('connect.$key', value);
}

/// The devices of one person, one of them playing and the others its remote controls (docs/PROTOCOL.md "Connect"). It
/// takes no part in rooms; it uses the library's sync key to find the other devices, and [Backend] for the one it is on.
///
/// Two jobs in one place, because the same device does both in turn:
///  - **playing**: it says what it plays to the others, answers their commands, and hands its queue over when asked;
///  - **controlling**: while another device plays it shows that one's state in place of its own ([events]) and sends the
///    commands there ([send]), so that the screens need not know where the sound comes from.
class ConnectController extends ChangeNotifier {
  ConnectController({
    required this.inner,
    required this._syncChanges,
    required this._syncKey,
    required this._server,
    required this._serverKey,
    required this.store,
    required this.kind,
    required this.defaultName,
    this.appVersion = '',
    this._opener,
    int Function()? nowMs,
    this.heartbeat = const Duration(seconds: 5),
    this.queueBeat = const Duration(seconds: 20),
    this.queueSettle = const Duration(milliseconds: 800),
    this.handoverGrace = const Duration(seconds: 3),
    this.pingEvery = const Duration(seconds: 45),
    this.probeAfter = const Duration(seconds: 6),
    this.volumeEvery = const Duration(milliseconds: 100),
    bool? buttonsAreLevels,
  }) : buttonsAreLevels = buttonsAreLevels ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS),
        _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The backend of this device, whose player is the one that plays here.
  final Backend inner;
  final ConnectStore store;
  /// What kind of device this is and what it is called until the person says: asked when needed, as a TV is known only once the
  /// app has asked the device.
  final DeviceKind Function() kind;
  final String Function() defaultName;
  final String appVersion;
  final Duration heartbeat;
  final Duration queueBeat;
  final Duration queueSettle;
  final Duration handoverGrace;
  final Duration pingEvery;
  final Duration probeAfter;
  final Duration volumeEvery;

  /// The buttons of the phone's volume reach the app only as a new level of the phone's volume (an iPhone), not as keys. While
  /// this device steers another, such a change is taken as a press, and the level of the phone is put back where it was.
  final bool buttonsAreLevels;
  final Listenable _syncChanges;
  final SyncKey? Function() _syncKey;
  final Future<Uri?> Function() _server;
  final Future<String> Function() _serverKey;
  final SocketOpener? _opener;
  final int Function() _now;

  // ------------------------------------------------------------------ what the screens read

  ConnectLink _link = ConnectLink.off;
  ConnectLink get link => _link;

  /// The devices of the person that are here, this one among them.
  List<ConnectDevice> get devices => _devices;
  List<ConnectDevice> _devices = const [];

  /// The devices that were here before and are not now (the server keeps them a month), the latest seen first.
  List<RecentDevice> get recent => _recent;
  List<RecentDevice> _recent = const [];

  String? _youId;
  String? get youId => _youId;
  String? _activeId;
  String? get activeId => _activeId;

  /// The sync key is there, so there is a cluster to be in.
  bool get enabled => _secrets != null;

  /// The device that plays; null when nobody does.
  ConnectDevice? get activeDevice => _activeId == null ? null : _devices.where((d) => d.id == _activeId).firstOrNull;

  /// Another device plays and this one shows and steers it.
  bool get controlling => !_inRoom && _link == ConnectLink.online && _activeId != null && _activeId != _youId && activeDevice != null;

  /// This device plays for the cluster.
  bool get playingHere => _link == ConnectLink.online && _activeId != null && _activeId == _youId;

  /// What the playing device last said, brought up to now; null when this device does not control.
  RemoteState? get remote => controlling ? _remote?.advanced(_serverNow) : null;

  /// The queue of the playing device.
  RemoteQueue? get remoteQueue => controlling ? _remoteQueue : null;

  /// The name of this device in the lists of the others.
  String get name => _name ?? defaultName();

  /// How many songs the last hand-over to this device left out because only the other device had them; the screen tells the
  /// person once and sets it back to 0.
  final ValueNotifier<int> dropped = ValueNotifier(0);

  /// The events of the backend, as the screens must see them: this device's own, unless it controls another one, whose state
  /// then takes the place of the player's, the queue's, the sleep timer's and the volume.
  Stream<BackendEvent> get events => _out.stream;

  // ------------------------------------------------------------------ inside

  final _out = StreamController<BackendEvent>.broadcast(sync: true);
  StreamSubscription<BackendEvent>? _innerSub;
  ConnectSecrets? _secrets;
  ConnectClient? _client;
  String? _name;
  var _inRoom = false;
  String? _clientId;
  RemoteState? _remote;
  RemoteQueue? _remoteQueue;
  var _remoteView = false;

  // The last of each that this device's own backend said, to put back when it stops controlling
  RoomSnapshot? _snapshot;
  PlayerPosition _position = const PlayerPosition();
  final _positionClock = Stopwatch();
  SleepState _sleep = const SleepState();
  double? _volume;
  BackendEvent? _lastSnapshotEvent;
  BackendEvent? _lastPositionEvent;
  BackendEvent? _lastSleepEvent;
  BackendEvent? _lastVolumeEvent;

  int get _serverNow => _client?.serverNow ?? _now();

  // Hosting
  var _rev = 0;
  String _stateSig = '';
  String _queueSig = '';
  var _statePublishedAt = 0;
  var _queuePublishedAt = 0;
  Timer? _stateTimer;
  Timer? _queueTimer;
  Timer? _beat;
  var _claiming = false;

  /// This device asked to play and the queue it is to play has not come yet: what it holds now is not what to tell the others.
  var _expectHandoff = false;
  var _handedOverAt = -1000000;

  /// This device let go of its queue for another one's and the other's state has not come yet: the screens keep what they
  /// showed, and not the empty player that is left.
  var _quiet = false;

  // The volume a finger sets goes out now and then, latest only; the player's own word on it waits until the finger rests
  double? _volumeToSend;
  Timer? _volumeTimer;
  var _volumeSetAt = -1000000;
  double? _lastSetVolume;
  var _wasPlaying = false;

  // An iPhone that steers another: the level its own volume is held at, so that a press of a button shows as a move from it, and
  // the level it had before (when that was put aside because a button would not move it any more: at an end of the range)
  double? _pinned;
  double? _pinnedFrom;

  // The messages are handled one after the other: opening a sealed one takes time and the order must stay
  Future<void>? _chain;
  final _sealedInfo = <String, DeviceInfo?>{};

  /// One short line in the log of the app, with no name and no content: what a person looking into a lost line needs.
  void _log(String line) => unawaited(inner.note('[connect] $line').catchError((Object _) {}));

  // ------------------------------------------------------------------ life

  /// Starts: reads what was kept, listens to the sync key and to the backend, and connects when there is a key.
  Future<void> start() async {
    _clientId = await store.read('client');
    if (_clientId == null) {
      final random = Random.secure();
      _clientId = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      await store.write('client', _clientId!);
    }
    final saved = await store.read('name');
    if (saved != null && saved.trim().isNotEmpty) _name = saved.trim();
    _innerSub = inner.events.listen(_onInner);
    _syncChanges.addListener(_keyChanged);
    await _keyChanged();
  }

  var _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _syncChanges.removeListener(_keyChanged);
    _innerSub?.cancel();
    _client?.stop();
    _stateTimer?.cancel();
    _queueTimer?.cancel();
    _beat?.cancel();
    _volumeTimer?.cancel();
    _out.close();
    dropped.dispose();
    super.dispose();
  }

  String? _openedFor;

  Future<void> _keyChanged() async {
    final key = _syncKey();
    if (key?.code == _openedFor) return;
    _openedFor = key?.code;
    _client?.stop();
    _client = null;
    _secrets = null;
    _reset();
    if (key == null) {
      _setLink(ConnectLink.off);
      notifyListeners();
      return;
    }
    final secrets = await ConnectSecrets.of(key);
    if (_openedFor != key.code) return;
    _secrets = secrets;
    final client = ConnectClient(
      secrets: secrets,
      clientId: _clientId!,
      address: () => _address(secrets),
      info: _sealInfo,
      onMessage: _enqueue,
      onLink: _setLink,
      opener: _opener,
      pingEvery: pingEvery,
      probeAfter: probeAfter,
      nowMs: _now,
    );
    _client = client;
    client.start();
    notifyListeners();
  }

  Future<Uri> _address(ConnectSecrets secrets) async {
    final base = await _server();
    if (base == null) throw StateError('no server');
    final key = await _serverKey();
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/connect/${secrets.clusterId}',
      queryParameters: key.isEmpty ? null : {'key': key},
    );
  }

  Future<String> _sealInfo() => ConnectSeal.seal(jsonEncode(_ownInfo.toJson()), _secrets!);

  DeviceInfo get _ownInfo => DeviceInfo(name: name, kind: kind(), app: appVersion, inRoom: _inRoom);

  void _reset() {
    _devices = const [];
    _recent = const [];
    _youId = null;
    _activeId = null;
    _remote = null;
    _remoteQueue = null;
    _claiming = false;
    _stateSig = '';
    _queueSig = '';
    _setRemoteView(false);
    _endQuiet();
  }

  void _setLink(ConnectLink link) {
    if (_link == link) return;
    _link = link;
    _log('line ${link.name}');
    if (link != ConnectLink.online) {
      // The line is gone: what was said of the others is not known to be true any more
      _devices = const [];
      _recent = const [];
      _activeId = null;
      _youId = null;
      _remote = null;
      _claiming = false;
      _setRemoteView(false);
      _endQuiet();
    }
    notifyListeners();
  }

  /// Tries to be back on the line now (the app was brought to the front).
  void nudge() => _client?.nudge();

  // ------------------------------------------------------------------ settings

  Future<void> rename(String value) async {
    final clean = value.trim();
    _name = clean.isEmpty ? null : clean;
    await store.write('name', clean);
    _sendInfo();
    notifyListeners();
  }

  void _sendInfo() {
    final secrets = _secrets;
    final client = _client;
    if (secrets == null || client == null) return;
    unawaited(() async {
      client.send({'t': 'info', 'info': await _sealInfo()});
    }());
  }

  // ------------------------------------------------------------------ what the screens ask

  /// Makes [id] the device that plays, with the queue that plays now. This device may be that one ("play here").
  void transferTo(String id) {
    if (_link != ConnectLink.online || id == _activeId) return;
    final target = _devices.where((d) => d.id == id).firstOrNull;
    if (target == null || (target.info?.inRoom ?? false)) return;
    _expectHandoff = id == _youId;
    _client?.send({'t': 'transfer', 'to': id});
  }

  /// Drops a device that is not here from the list of the ones seen (it is back in it when it comes again).
  void forget(String id) {
    if (_link != ConnectLink.online || !_recent.any((d) => d.id == id)) return;
    _recent = [for (final d in _recent) if (d.id != id) d];
    notifyListeners();
    _client?.send({'t': 'forget', 'id': id});
  }

  /// How long ago [device] was seen, on the clock of the server.
  Duration seenAgo(RecentDevice device) => Duration(milliseconds: max(0, _serverNow - device.seenAt));

  /// Plays on this device, taking what plays on another one along.
  void playHere() {
    final id = _youId;
    if (id != null) transferTo(id);
  }

  /// Does [command] on the device that plays. False when this device does not control one.
  bool send(RemoteCommand command) {
    final to = _activeId;
    if (!controlling || to == null) return false;
    _guess(command);
    unawaited(() async {
      final blob = await ConnectSeal.seal(jsonEncode(command.toJson()), _secrets!);
      _client?.send({'t': 'cmd', 'to': to, 'blob': blob});
    }());
    return true;
  }

  /// Sets the volume of the device that plays. Many come while a finger drags (the server takes 20 messages a second), so
  /// only the latest is sent, now and then; and what the player says back is not shown until the finger has been still a while,
  /// or the bar would jump back under it. False when this device does not control one.
  bool sendVolume(double level) {
    if (!controlling) return false;
    _volumeSetAt = _now();
    _lastSetVolume = level;
    _volumeToSend = level;
    _volumeTimer ??= Timer(volumeEvery, () {
      _volumeTimer = null;
      final value = _volumeToSend;
      _volumeToSend = null;
      if (value != null) send(RemoteCommand('volume', {'level': value}));
    });
    return true;
  }

  /// A press of a button of the phone's volume while this device steers another: the volume of that one goes up ([way] 1) or
  /// down (-1) by a step, and the bars show it at once. Gives the new level, or null when this device does not steer one (the
  /// press is the system's).
  double? nudgeVolume(int way) {
    if (!controlling) return null;
    final held = _now() - _volumeSetAt <= 1500 ? _lastSetVolume : null;
    final base = held ?? _remote?.volume ?? 0.5;
    final level = (base + way * volumeStep).clamp(0.0, 1.0).toDouble();
    _out.add(VolumeEvent(level));
    sendVolume(level);
    return level;
  }

  /// One press of a volume button moves the volume by this much of its range, as the sheet's bar does by key.
  static const volumeStep = 0.0625;

  /// What a command is sure to do on the player, shown at once: the pause or the play, the place that was sought, the mode.
  void _guess(RemoteCommand command) {
    final state = _remote?.advanced(_serverNow);
    if (state == null) return;
    final now = _serverNow;
    final next = switch (command.name) {
      'play' => state.guessed(playing: true, at: now),
      'pause' => state.guessed(playing: false, at: now),
      'seek' => state.guessed(positionMs: (command.args['ms'] as num).toInt(), at: now),
      'repeat' => state.guessed(repeat: command.args['mode'] as String?),
      'setShuffle' => state.guessed(shuffle: command.args['on'] == true),
      _ => null,
    };
    if (next == null) return;
    _remote = next;
    _emitView();
  }

  // ------------------------------------------------------------------ what the server says

  void _enqueue(ConnectMessage message) {
    _chain = (_chain ?? Future<void>.value()).then((_) => _handle(message)).catchError((Object e) {
      unawaited(inner.note('[connect] ${message['t']} failed: $e').catchError((Object _) {}));
    });
  }

  Future<void> _handle(ConnectMessage m) async {
    switch (m['t']) {
      case 'welcome':
        _log('welcome devices=${(m['devices'] as List?)?.length} active=${m['active'] == null ? 'none' : (m['active'] == m['you'] ? 'me' : 'other')} state=${m['state'] != null} queue=${m['queue'] != null}');
        _youId = m['you'] as String?;
        await _setDevices(m['devices'], m['recent']);
        _activeId = m['active'] as String?;
        _remote = await _openState(m['state']);
        _remoteQueue = await _openQueue(m['queue']);
        _afterChange();
        // This device is the one that was playing before the line dropped: it goes on, and says where it is
        if (playingHere) _publish(force: true, withQueue: true);
        // Another device took the playing while the line was down: this one, still playing, stops (the cluster has moved on)
        if (_activeId != null && _activeId != _youId) {
          _stopForOther(dropQueue: false);
        } else {
          // It played by itself while the line was down
          _maybeClaim();
        }
      case 'devices':
        await _setDevices(m['devices'], m['recent']);
        _activeId = m['active'] as String?;
        _afterChange();
      case 'active':
        final wasMine = _activeId != null && _activeId == _youId;
        _log('active ${m['device'] == null ? 'none' : (m['device'] == _youId ? 'me' : 'other')}');
        _activeId = m['device'] as String?;
        _claiming = false;
        if (_activeId != _youId) {
          _remote = null;
          _expectHandoff = false;
          // It was this device's and is another's now: whatever still sounds here stops, whether or not it was asked to let go
          if (wasMine) _stopForOther();
        }
        _afterChange();
        if (playingHere && !_expectHandoff) _publish(force: true, withQueue: true);
      case 'state':
        final state = await _openState(m['blob']);
        final current = _remote;
        if (state != null && (current == null || state.rev >= current.rev || state.itemId != current.itemId)) {
          _remote = state;
          _afterChange();
        }
      case 'queue':
        _remoteQueue = await _openQueue(m['blob']);
        _afterChange();
      case 'cmd':
        await _onCommand(m['blob']);
      case 'release':
        _log('release');
        await _handOver();
      case 'handoff':
        await _takeOver(m['blob']);
      case 'deposed':
        _log('deposed');
        // Somebody else began to play: this one stops where it is
        _handedOverAt = _now();
        await inner.pause();
        await _letGo();
      case 'error':
        unawaited(inner.note('[connect] error ${m['code']}').catchError((Object _) {}));
    }
  }

  Future<DeviceInfo?> _openInfo(String id, String sealed, ConnectSecrets secrets) async {
    final key = '$id/$sealed';
    if (!_sealedInfo.containsKey(key)) {
      final text = sealed.isEmpty ? null : await ConnectSeal.open(sealed, secrets);
      _sealedInfo[key] = text == null ? null : DeviceInfo.fromJson(_tryJson(text));
    }
    return _sealedInfo[key];
  }

  /// [past] is the server's list of the devices seen before (a server that does not keep one sends none).
  Future<void> _setDevices(Object? list, [Object? past]) async {
    final secrets = _secrets;
    if (secrets == null || list is! List) return;
    final out = <ConnectDevice>[];
    for (final d in list) {
      if (d is! Map) continue;
      final id = d['id'] as String?;
      if (id == null) continue;
      out.add(ConnectDevice(id: id, info: await _openInfo(id, d['info'] as String? ?? '', secrets), you: id == _youId));
    }
    final before = <RecentDevice>[];
    if (past is List) {
      for (final d in past) {
        if (d is! Map) continue;
        final id = d['id'] as String?;
        final seen = d['seen'];
        if (id == null || seen is! num) continue;
        before.add(RecentDevice(id: id, info: await _openInfo(id, d['info'] as String? ?? '', secrets), seenAt: seen.toInt()));
      }
    }
    _recent = before;
    // This device first, then the one that plays, then the rest in the order they came
    out.sort((a, b) => (b.you ? 2 : 0) + (b.id == _activeId ? 1 : 0) - ((a.you ? 2 : 0) + (a.id == _activeId ? 1 : 0)));
    _devices = out;
  }

  Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<RemoteState?> _openState(Object? blob) async {
    final secrets = _secrets;
    if (secrets == null || blob == null) return null;
    final sealed = blob is Map ? blob['blob'] : blob;
    if (sealed is! String) return null;
    final text = await ConnectSeal.open(sealed, secrets);
    return text == null ? null : RemoteState.fromJson(_tryJson(text));
  }

  Future<RemoteQueue?> _openQueue(Object? blob) async {
    final secrets = _secrets;
    if (secrets == null || blob is! String) return null;
    final text = await ConnectSeal.open(blob, secrets);
    final payload = text == null ? null : _tryJson(text);
    return payload is Map ? RemoteQueue.fromExport(payload['saved']) : null;
  }

  void _afterChange() {
    final view = controlling && _remote != null;
    _setRemoteView(view);
    if (view) {
      _quiet = false;
      _emitView();
    } else if (_quiet && (playingHere || _activeId == null)) {
      _endQuiet();
    }
    notifyListeners();
  }

  /// The screens hear this device's own player again.
  void _endQuiet() {
    if (!_quiet) return;
    _quiet = false;
    if (_remoteView) return;
    for (final e in [_lastSnapshotEvent, _lastPositionEvent, _lastSleepEvent, _lastVolumeEvent]) {
      if (e != null) _out.add(e);
    }
  }

  // ------------------------------------------------------------------ controlling: what the screens see

  /// Switches what the screens see between the other device's state and this one's own. Going back to its own, they are told
  /// what it was ([except] is what is being said anyway).
  void _setRemoteView(bool on, {BackendEvent? except}) {
    if (_remoteView == on) return;
    _remoteView = on;
    if (buttonsAreLevels) on ? _holdPhoneVolume() : _releasePhoneVolume();
    if (!on) {
      for (final e in [_lastSnapshotEvent, _lastPositionEvent, _lastSleepEvent, _lastVolumeEvent]) {
        if (e != null && !identical(e, except)) _out.add(e);
      }
    }
  }

  /// Starts to hold the phone's own volume still (it moves to the middle first when it is at an end, where a button would not
  /// show), so that its buttons can steer the other device.
  void _holdPhoneVolume() {
    final level = _volume;
    if (level == null) return;
    _pinned = level < 0.2 || level > 0.8 ? 0.5 : level;
    if (_pinned != level) {
      _pinnedFrom = level;
      unawaited(inner.setVolume(_pinned!).catchError((Object _) {}));
    }
  }

  void _releasePhoneVolume() {
    final from = _pinnedFrom;
    _pinned = null;
    _pinnedFrom = null;
    if (from != null) unawaited(inner.setVolume(from).catchError((Object _) {}));
  }

  void _emitView() {
    final remote = _remote?.advanced(_serverNow);
    if (remote == null) return;
    final entries = _remoteQueue?.entries ?? const <QueueEntry>[];
    var queue = entries;
    var index = remote.itemId == null ? -1 : entries.indexWhere((e) => e.id == remote.itemId);
    if (index < 0) {
      // The queue has not come, or is older than the state: the song that plays is all there is to show
      queue = remote.current == null ? entries : [remote.current!];
      index = remote.current == null ? remote.index : 0;
    }
    final own = _snapshot;
    _out.add(
      StateEvent(
        RoomSnapshot(
          you: own?.you,
          television: own?.television ?? false,
          phase: remote.phase,
          index: index < 0 ? 0 : index,
          repeat: Repeat.parse(remote.repeat),
          queue: queue,
          shuffle: remote.shuffle,
          label: remote.label,
          loading: remote.loading,
          playbackSpeed: remote.speed,
        ),
      ),
    );
    _out.add(
      PositionEvent(
        PlayerPosition(
          playing: remote.playing,
          buffering: remote.buffering,
          positionMs: remote.positionMs,
          durationMs: remote.durationMs,
          speed: remote.speed,
        ),
      ),
    );
    final endsAt = remote.sleep.endsAt;
    _out.add(
      SleepEvent(
        SleepState(
          mode: remote.sleep.mode,
          endsAt: endsAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endsAt.millisecondsSinceEpoch - (_client?.clockOffsetMs ?? 0)),
        ),
      ),
    );
    if (remote.volume != null && _now() - _volumeSetAt > 1500) _out.add(VolumeEvent(remote.volume!));
  }

  // ------------------------------------------------------------------ what this device's own backend says

  void _onInner(BackendEvent event) {
    switch (event) {
      case StateEvent(:final snapshot):
        _snapshot = snapshot;
        _lastSnapshotEvent = event;
        _noteRoom(snapshot.inRoom);
      case PositionEvent(:final position):
        _position = position;
        _positionClock
          ..reset()
          ..start();
        _lastPositionEvent = event;
      case SleepEvent(:final sleep):
        _sleep = sleep;
        _lastSleepEvent = event;
      case VolumeEvent(:final level):
        if (_pinned != null && _remoteView) {
          // The phone's volume is held still while it steers another: what moves it is a button, which is for the other's
          final held = _pinned!;
          if ((level - held).abs() > 0.001) {
            nudgeVolume(level > held ? 1 : -1);
            unawaited(inner.setVolume(held).catchError((Object _) {}));
          }
          return;
        }
        _volume = level;
        _lastVolumeEvent = event;
      default:
        break;
    }
    final own = event is StateEvent || event is PositionEvent || event is SleepEvent || event is VolumeEvent;
    // A device that went into a room is no more a remote control: its own state is what the room's screens need
    if (own && _remoteView && !controlling) _setRemoteView(false, except: event);
    // While another device plays, what this one's player says is not what the screens are to show
    if (!(own && (_remoteView || _quiet))) _out.add(event);
    if (event is PositionEvent) _maybeClaim();
    if (own) _publish();
  }

  void _noteRoom(bool inRoom) {
    if (_inRoom == inRoom) return;
    _inRoom = inRoom;
    _sendInfo();
    // A person's devices and a room never mix: a device that went into one is not the one that plays
    if (inRoom && _activeId == _youId && _activeId != null) _client?.send({'t': 'stop'});
    _afterChange();
  }

  /// Sound begins on this device by its own doing (a button of the notification, a headset, a widget): then it is the one that
  /// plays, and the one that did is told to stop.
  void _maybeClaim() {
    if (_link != ConnectLink.online || _claiming || _inRoom || _activeId == _youId) return;
    if (!_position.playing || _now() - _handedOverAt < handoverGrace.inMilliseconds) return;
    _claiming = true;
    _log('claim');
    _client?.send({'t': 'claim'});
  }

  // ------------------------------------------------------------------ playing: what this device tells the others

  /// What is current, and the song of it.
  ({String? id, QueueEntry? song}) get _currentSong {
    final song = _snapshot?.current;
    return (id: song?.id, song: song);
  }

  RemoteState _buildState() {
    final s = _snapshot ?? const RoomSnapshot();
    final p = _position;
    final elapsed = p.playing ? (_positionClock.elapsedMilliseconds * p.speed).round() : 0;
    final position = p.durationMs > 0 ? min(p.positionMs + elapsed, p.durationMs) : p.positionMs + elapsed;
    final endsAt = _sleep.endsAt;
    final current = _currentSong;
    return RemoteState(
      rev: ++_rev,
      itemId: current.id,
      current: current.song,
      phase: s.phase,
      index: s.myIndex,
      repeat: s.repeat.name,
      shuffle: s.shuffle ?? false,
      label: s.label,
      loading: s.loading,
      playing: p.playing,
      buffering: p.buffering,
      positionMs: position,
      durationMs: p.durationMs > 0 ? p.durationMs : (current.song?.durMs ?? 0),
      speed: p.speed,
      at: _serverNow,
      volume: _volume,
      video: s.video,
      sleep: SleepState(
        mode: _sleep.mode,
        endsAt: endsAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endsAt.millisecondsSinceEpoch + (_client?.clockOffsetMs ?? 0)),
      ),
    );
  }

  String _signature() {
    final s = _snapshot;
    final p = _position;
    return [
      s?.phase,
      _currentSong.id,
      s?.repeat.name,
      s?.shuffle,
      s?.label,
      s?.loading,
      s?.video,
      p.playing,
      p.buffering,
      p.speed,
      p.durationMs,
      _volume?.toStringAsFixed(2),
      _sleep.mode.name,
      _sleep.endsAt?.millisecondsSinceEpoch,
    ].join('|');
  }

  String _queueSignature() {
    final s = _snapshot;
    if (s == null) return '';
    return '${s.label}|${s.shuffle}|${s.queue.map((e) => '${e.id}${e.queued ? '!' : ''}${e.auto ? '~' : ''}').join(',')}';
  }

  /// Tells the others what plays, when it changed and now and then while it plays; the queue when it changed, apart.
  void _publish({bool force = false, bool withQueue = false}) {
    if (!playingHere || _inRoom || _snapshot == null) return;
    final now = _now();
    final changed = _signature() != _stateSig;
    // A seek is a jump of the position that the extrapolation did not foresee
    final sinceHeartbeat = now - _statePublishedAt;
    final due = changed || force || (_position.playing && sinceHeartbeat >= heartbeat.inMilliseconds);
    if (due) {
      if (sinceHeartbeat < 250 && !force) {
        _stateTimer ??= Timer(const Duration(milliseconds: 250), () {
          _stateTimer = null;
          _publish();
        });
      } else {
        _stateTimer?.cancel();
        _stateTimer = null;
        _sendState();
      }
    }
    final queueChanged = _queueSignature() != _queueSig;
    final queueDue = withQueue || queueChanged || (_position.playing && now - _queuePublishedAt >= queueBeat.inMilliseconds) || (_wasPlaying && !_position.playing);
    _wasPlaying = _position.playing;
    if (queueDue) {
      _queueTimer?.cancel();
      _queueTimer = Timer(withQueue ? Duration.zero : queueSettle, () {
        _queueTimer = null;
        unawaited(_sendQueue());
      });
    }
    _beat ??= Timer.periodic(heartbeat, (_) {
      if (playingHere && _position.playing) _publish();
    });
  }

  void _sendState() {
    final secrets = _secrets;
    final client = _client;
    if (secrets == null || client == null) return;
    final state = _buildState();
    _stateSig = _signature();
    _statePublishedAt = _now();
    unawaited(() async {
      client.send({'t': 'state', 'rev': state.rev, 'blob': await ConnectSeal.seal(jsonEncode(state.toJson()), secrets)});
    }());
  }

  Future<void> _sendQueue() async {
    final secrets = _secrets;
    final client = _client;
    if (secrets == null || client == null || !playingHere) return;
    final handover = await inner.queueExport();
    if (handover == null) return;
    _queueSig = _queueSignature();
    _queuePublishedAt = _now();
    final payload = jsonEncode({'play': true, 'dropped': handover.dropped, 'saved': jsonDecode(handover.json)});
    client.send({'t': 'queue', 'blob': await ConnectSeal.seal(payload, secrets)});
  }

  /// Tells the screens where a queue that is not playing stands: the song, and where it resumes.
  void _showRestingPosition(RemoteQueue? queue, Object? positionMs) {
    final entries = queue?.entries ?? const <QueueEntry>[];
    if (entries.isEmpty) return;
    final at = queue!.index.clamp(0, entries.length - 1);
    final event = PositionEvent(PlayerPosition(positionMs: (positionMs as num?)?.toInt() ?? 0, durationMs: entries[at].durMs));
    _position = event.position;
    _positionClock
      ..reset()
      ..start();
    _lastPositionEvent = event;
    if (!_remoteView) _out.add(event);
  }

  // ------------------------------------------------------------------ playing: what the others ask

  Future<void> _onCommand(Object? blob) async {
    final secrets = _secrets;
    if (secrets == null || blob is! String || !playingHere) return;
    final text = await ConnectSeal.open(blob, secrets);
    final command = text == null ? null : RemoteCommand.fromJson(_tryJson(text));
    if (command != null) await command.run(inner);
  }

  /// Another device plays: this one's player stops where it is, and the sound it still makes does not take the playing back.
  ///
  /// [dropQueue] false leaves a queue that is only waiting: a device that has just started and has not played in this cluster
  /// has songs of its own that nobody took over.
  void _stopForOther({bool dropQueue = true}) {
    final sounding = _position.playing || _position.buffering || (_snapshot?.loading ?? false);
    if (sounding) {
      _handedOverAt = _now();
      _log('stop for other');
      unawaited(inner.pause().catchError((Object _) {}));
    }
    if (sounding || dropQueue) unawaited(_letGo());
  }

  /// Another device holds the queue now: this one drops its own, so that its player neither loads songs nor keeps a
  /// notification for them. The queue is back with the next hand-over to this device. A room's queue is not the person's.
  Future<void> _letGo() async {
    if (_inRoom || (_snapshot?.queue.isEmpty ?? true)) return;
    _quiet = true;
    try {
      await inner.clear();
    } on Object {
      // The player cannot be told: it stays paused, as it was
    }
  }

  Future<void> _handOver() async {
    final secrets = _secrets;
    final client = _client;
    if (secrets == null || client == null) return;
    final playing = _position.playing || _position.buffering || (_snapshot?.loading ?? false);
    await inner.pause();
    final handover = await inner.queueExport();
    _handedOverAt = _now();
    final payload = jsonEncode({
      'play': playing,
      'dropped': handover?.dropped ?? 0,
      'saved': handover == null ? null : jsonDecode(handover.json),
    });
    client.send({'t': 'handoff', 'blob': await ConnectSeal.seal(payload, secrets)});
    if (handover != null) await _letGo();
  }

  /// This device is to play, with the queue another one handed over (or the last that was kept).
  Future<void> _takeOver(Object? blob) async {
    final secrets = _secrets;
    if (secrets == null) return;
    _claiming = false;
    try {
      if (blob is! String) return;
      final text = await ConnectSeal.open(blob, secrets);
      final payload = text == null ? null : _tryJson(text);
      if (payload is! Map || payload['saved'] == null) return;
      final play = payload['play'] != false;
      final left = (payload['dropped'] as num?)?.toInt() ?? 0;
      final done = await inner.queueImport(jsonEncode(payload['saved']), play: play);
      _log('takeover imported=$done play=$play dropped=$left');
      if (done && left > 0) dropped.value = left;
      // A queue that waits (it was paused) makes no sound and no news from the player: the screens are told where it stands
      if (done && !play) _showRestingPosition(RemoteQueue.fromExport(payload['saved']), (payload['saved'] as Map)['positionMs']);
    } finally {
      _expectHandoff = false;
      // The state follows from what the player says next; the queue is what was handed over
      _publish(withQueue: true);
    }
  }
}
