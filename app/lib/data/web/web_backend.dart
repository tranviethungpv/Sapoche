import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../backend.dart';
import '../models.dart';
import '../music_models.dart';
import 'backend_defaults.dart';
import 'chat_cipher.dart';
import 'clocks.dart';
import 'group_session.dart';
import 'library_store.dart';
import 'listen_tracker.dart';
import 'local_session.dart';
import 'lyrics_client.dart';
import 'push_port.dart';
import 'music_client.dart';
import 'music_feed.dart';
import 'player_port.dart';
import 'room_client.dart';
import 'room_socket.dart';
import 'sleep_timer.dart';
import 'suggestion_feed.dart';
import 'taste.dart';
import 'wire.dart';
import 'youtube_links.dart';

/// What the browser shows outside the page about what plays (media keys, the lock screen, the notification of a phone)
/// and what it can ask of the app from there.
abstract interface class MediaControls {
  /// Tells the browser what plays now; a null [title] says nothing does.
  void update({String? title, String? artist, String? artwork, required bool playing});

  /// Where the browser's own buttons go.
  void bind({
    required void Function() play,
    required void Function() pause,
    required void Function() next,
    required void Function() prev,
    required void Function(int positionMs) seek,
  });
}

/// [Backend] for a browser: the room connection and the sync of the app, in Dart, and the YouTube player of the page
/// in place of the native player. What the phones do in Kotlin and Swift (the personal queue, the library, YouTube
/// Music pages) comes to it step by step, see [BackendDefaults] for what it still leaves out.
class WebBackend extends BackendDefaults {
  WebBackend({
    required this.player,
    required this.prefs,
    required this.defaultServer,
    LibraryStore? library,
    http.Client? client,
    NowMs? nowMs,
    Random? random,
    this._opener,
    this.region = _usa,
    this.invite,
    this.openChat = false,
    this.inviteSecret,
    this.secretsDisk,
    this.onShare,
    this.media,
    this.push,
    this.appVersion,
    this.sink = _ignore,
  }) : _http = client ?? http.Client(),
       _library = library ?? LibraryStore(),
       _random = random ?? Random.secure() {
    _library
      ..onChanged = (() => _events.add(const LibraryEvent()))
      ..unnamed = () => _language == 'vi' ? 'Chưa đặt tên' : 'Untitled';
    final watch = Stopwatch()..start();
    _now = nowMs ?? () => watch.elapsedMilliseconds;
    _events = StreamController<BackendEvent>.broadcast(
      // The screen waits for a first state before it shows anything
      onListen: () {
        _positionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _emitPosition());
        scheduleMicrotask(() {
          _emitState();
          _events.add(SleepEvent(_sleep.state));
          _renewSuggestionsIfDue();
          final code = invite;
          if (code != null && !_invited) {
            _invited = true;
            _followNotice(code);
          }
        });
      },
      onCancel: () {
        _positionTimer?.cancel();
        _positionTimer = null;
      },
    );
    SavedQueue? saved;
    try {
      saved = SavedQueue.fromJson(jsonDecode(prefs.getString(_keyLocalQueue) ?? 'null'));
    } on Object {
      // A queue that cannot be read is no queue
    }
    _local = LocalSession(
      player: player,
      saved: saved,
      persist: _persistQueue,
      problem: (p) => _events.add(ErrorEvent(ServerError(p.kind.code, p.title))),
      log: (m) => _note('local: $m'),
      onQueueEnd: _autoplay,
    )..attach();
    player
      ..onPausedAtEnd = _sleep.songEnded
      ..setVideoHeight(_videoHeight);
    media?.bind(
      play: () => play().ignore(),
      pause: () => pause().ignore(),
      next: () => next().ignore(),
      prev: () => prev().ignore(),
      seek: (ms) => seek(ms).ignore(),
    );
    push?.opened.listen((room) => _events.add(OpenChatEvent(room)));
    try {
      _secrets = {
        for (final e in (jsonDecode(prefs.getString(_keyEnc) ?? '{}') as Map<String, dynamic>).entries) e.key: e.value as String,
      };
    } on Object {
      // Secrets that cannot be read are none
    }
    // A link with a secret in it: the chat of that room can be read from the start
    final joining = invite;
    final given = inviteSecret;
    if (joining != null && given != null && ChatCipher.decodeSecret(given) != null) _keepSecret(joining, given);
    _local.changes.listen((_) {
      _emitState();
      // The player starts right after the queue says it is loaded: tell the screen how it stands once it has
      scheduleMicrotask(_emitPosition);
    });
  }

  static void _ignore(String _) {}
  static String _usa() => 'US';

  final PlayerPort player;
  final SharedPreferences prefs;

  /// Where the page came from: the room server serves the app, so this is its address.
  final String defaultServer;
  /// Where the lines of the diary go (the console of the browser).
  final void Function(String line) sink;

  /// The country whose music YouTube Music shows first, as a code like "VN"; follows the browser.
  final String Function() region;

  /// The room of the link the page was opened with, which the screen offers to join once.
  final String? invite;

  /// Hands text to the browser's share sheet, or its clipboard; null where there is neither.
  final Future<void> Function(String text)? onShare;
  final MediaControls? media;

  /// The browser's notices of the chat while the page is away; null where there is no such thing (the tests).
  final PushPort? push;

  /// The version of this app, like `1.26.0`, which the room shows to the other members; null when the page cannot say.
  final String? appVersion;
  final http.Client _http;
  final LibraryStore _library;
  late final _listens = ListenTracker(skipped: (id, durationMs) => _skipped(id, durationMs), heard: (id, durationMs) => _heard(id, durationMs));
  QueueEntry? _listened;
  final SocketOpener? _opener;
  final Random _random;
  late final NowMs _now;
  late final StreamController<BackendEvent> _events;
  late final LocalSession _local;
  var _invited = false;

  /// The secret that came with the link, for the room [invite]; the page takes it out of the address.
  final String? inviteSecret;

  /// Where the secrets are also kept for the service worker of the page, which opens the previews of notices with them.
  final LibraryDisk? secretsDisk;

  /// The secrets of the rooms with end-to-end encrypted chat, by room code, as they are written in an invitation link.
  var _secrets = <String, String>{};
  static const _keyEnc = 'web.enc';

  /// The chat is worked on in order, as it comes: opening a sealed message takes a moment of the browser's own.
  Future<void> _chatWork = Future.value();

  void _keepSecret(String room, String secret) {
    _secrets = {..._secrets, room.toUpperCase(): secret};
    final json = jsonEncode(_secrets);
    prefs.setString(_keyEnc, json);
    secretsDisk?.write(json).ignore();
  }

  /// The link came from a touch on a notice of the chat: into the room, and its chat opens when it is there.
  final bool openChat;

  /// The room whose chat opens as soon as the room has told it.
  String? _chatWhenReady;

  /// An invitation link arrived: the screen offers the room, or, from a notice of the chat, the person goes straight in
  /// when this browser has what it takes (a name and the key) and the chat opens.
  void _followNotice(String code) {
    final name = prefs.getString(_keyName);
    if (openChat && name != null && name.isNotEmpty && _server.isNotEmpty && _key.isNotEmpty) {
      _chatWhenReady = code;
      _enter(code, name, create: false);
      return;
    }
    _events.add(InviteEvent(code));
  }

  static const _keyServer = 'web.server';
  static const _keyKey = 'web.key';
  static const _keyName = 'web.name';
  static const _keyClientId = 'web.clientId';
  static const _keyStartBias = 'web.startBias';
  static const _keyTrim = 'web.trim';
  static const _keyLocalQueue = 'web.localQueue';
  static const _keyAutoplay = 'web.autoplay';
  static const _keyVideo = 'web.video';
  static const _keyVideoHeight = 'web.videoHeight';
  static const _chatKept = 200;

  @override
  Stream<BackendEvent> get events => _events.stream;

  // ------------------------------------------------------------------ settings

  String get _server {
    final saved = prefs.getString(_keyServer) ?? '';
    return saved.isEmpty ? defaultServer : saved;
  }

  String get _key => prefs.getString(_keyKey) ?? '';

  /// An address cleaned of spaces and a closing slash; one without a scheme is taken to be https.
  static String cleanAddress(String address) {
    var text = address.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isNotEmpty && !text.contains('://')) text = 'https://$text';
    return text;
  }

  String get _clientId {
    var id = prefs.getString(_keyClientId);
    if (id == null) {
      id = [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      prefs.setString(_keyClientId, id);
    }
    return id;
  }

  Map<String, String> get _authHeaders => _key.isEmpty ? const {} : {'X-Sapoche-Key': _key};

  @override
  Future<Profile> profile() async => Profile(
    name: prefs.getString(_keyName),
    device: 'Web',
    trimMs: prefs.getInt(_keyTrim) ?? 0,
    server: _server,
    autoplay: _autoplayOn,
    configured: _server.isNotEmpty,
    hasKey: _key.isNotEmpty,
  );

  /// A link that opens this app with the key already in it (see index.html), for sending to the people of the group.
  /// It holds the key, so it is only for the person to see.
  @override
  Future<String?> setupLink() async =>
      _key.isEmpty || _server.isEmpty ? null : '$_server/#key=${Uri.encodeComponent(_key)}';

  @override
  Future<void> configure({String? server, String? key}) async {
    if (server != null) await prefs.setString(_keyServer, cleanAddress(server));
    if (key != null) await prefs.setString(_keyKey, key.trim());
  }

  void _requireSetUp() {
    if (_server.isEmpty || _key.isEmpty) {
      throw BackendException('not_configured', 'Set the server first');
    }
  }

  // ------------------------------------------------------------------ rooms

  RoomClient? _roomClient;
  GroupSession? _session;
  StreamSubscription<RoomEvent>? _sessionEvents;
  String? _roomCode;
  Connection? _connection;
  Timer? _positionTimer;

  /// The chat as the room last said it; null until its history came (a server older than protocol 10 sends none).
  List<ChatMessage>? _chatLog;
  var _deliveredUpTo = 0;

  @override
  Future<RoomInfo?> roomInfo(String code) async {
    final clean = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(clean) || _server.isEmpty) return null;
    try {
      final reply = await _http.get(Uri.parse('$_server/room/$clean/info'), headers: _authHeaders);
      if (reply.statusCode < 200 || reply.statusCode >= 300) return null;
      return RoomInfo.fromMap(jsonDecode(reply.body) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  @override
  Future<String> createRoom(String name) async {
    _requireSetUp();
    final http.Response reply;
    try {
      reply = await _http.post(Uri.parse('$_server/rooms'), headers: _authHeaders);
    } on Object {
      throw BackendException('failed', 'The server cannot be reached');
    }
    if (reply.statusCode < 200 || reply.statusCode >= 300) {
      throw BackendException(
        'failed',
        reply.statusCode == 401 ? 'The server turned the key down' : 'The server answered ${reply.statusCode}',
      );
    }
    final code = (jsonDecode(reply.body) as Map<String, dynamic>)['code'] as String?;
    if (code == null) throw BackendException('failed', 'The server gave no room code');
    _enter(code, name, create: true);
    return code;
  }

  @override
  Future<void> join(String code, String name) async {
    _requireSetUp();
    _enter(code.trim().toUpperCase(), name, create: false);
  }

  void _enter(String code, String name, {required bool create}) {
    _stopFollowing(deliberate: true);
    _local.detach();
    _flushQueue();
    prefs.setString(_keyName, name);
    final session = GroupSession(
      player: player,
      clock: _clock,
      nowMs: _now,
      send: (text) => _roomClient?.send(text),
      log: (m) => _note('sync: $m'),
      // A frame of the YouTube player takes only a few fixed speeds, so a device in a room is moved by seeking alone
      drift: DriftController(speedDelta: 0, seekThresholdMs: _seekThresholdMs),
    )..trimMs = prefs.getInt(_keyTrim) ?? 0
     ..startBiasMs = prefs.getInt(_keyStartBias) ?? 0
     ..onStartBiasLearned = (bias) => prefs.setInt(_keyStartBias, bias);
    final client = RoomClient(
      baseUrl: Uri.parse(_server),
      roomCode: code,
      clientId: _clientId,
      name: name,
      clock: _clock,
      nowMs: _now,
      key: _key,
      create: create,
      appVersion: appVersion,
      probeAuth: _probeAuth(code),
      opener: _opener,
      log: (m) => _note('room: $m'),
    );
    client.onMessage = (message) {
      if (message is ErrorMessage) _events.add(ErrorEvent(ServerError(message.code, message.message)));
      if (message is AutoplayFillMessage) _fillRoom(message);
      _onChat(code, message);
      session.onMessage(message);
    };
    client.onConnected = session.onReconnected;
    client.onAvatar = (id, _, data) => _events.add(AvatarEvent(id, data == null ? null : base64Decode(data)));
    client.setAvatar(_avatar);
    client.onConnection = (c) {
      _connection = c;
      _emitState();
      // Turned away for good (full, gone, removed): back outside a room
      if (c == Connection.refused) scheduleMicrotask(() => _stopFollowing(deliberate: false));
    };
    session.onSnapshot = (_) => _emitState();
    _sessionEvents = session.events.listen(_onSessionEvent);

    _session = session;
    _roomClient = client;
    _roomCode = code;
    _connection = Connection.connecting;
    _emitState();
    client.start();
    _offerPush().ignore();
  }

  final _clock = ClockSync();
  final _diary = <String>[];

  void _note(String line) {
    _diary.add(line);
    if (_diary.length > 300) _diary.removeAt(0);
    sink(line);
  }

  @override
  Future<List<String>> log() async => List.of(_diary);

  @override
  Future<void> note(String line) async => _note('ui: $line');

  /// Seeking in a frame of the YouTube player costs a few hundred milliseconds, so a drift smaller than that is not
  /// worth a seek; measured on the first real rooms, see docs/WEB.md.
  static const _seekThresholdMs = 600;

  Future<int?> Function() _probeAuth(String code) => () async {
    try {
      final reply = await _http.get(Uri.parse('$_server/room/$code/info'), headers: _authHeaders);
      return reply.statusCode;
    } on Object {
      return null;
    }
  };

  @override
  Future<void> leave() async => _stopFollowing(deliberate: true);

  void _stopFollowing({required bool deliberate}) {
    final client = _roomClient;
    if (client == null) return;
    if (deliberate) {
      client.leave();
    } else {
      client.close();
    }
    _session?.close();
    _sessionEvents?.cancel();
    _local.attach(); // the personal queue gets the player back, paused where it was
    _roomClient = null;
    _session = null;
    _roomCode = null;
    _connection = null;
    _chatLog = null;
    _chatWhenReady = null;
    _deliveredUpTo = 0;
    _lastKey = null;
    _emitState();
  }

  @override
  Future<void> rename(String name) async {
    prefs.setString(_keyName, name);
    _roomClient?.rename(name);
  }

  GroupSession _inRoom() {
    final session = _session;
    if (session == null) throw BackendException('no_room', 'This device is not in a room');
    return session;
  }

  bool _send(String text) => _roomClient?.send(text) ?? false;

  @override
  Future<void> kick(String memberId) async {
    _inRoom();
    _send(Wire.kick(memberId));
  }

  @override
  Future<void> setRoomName(String name) async {
    _inRoom();
    _send(Wire.roomName(name));
  }

  @override
  Future<void> setRoomTheme(String theme, {String? background}) async {
    _inRoom();
    _send(Wire.roomTheme(theme, background));
  }

  @override
  Future<void> setGuestControl(GuestControl mode) async {
    _inRoom();
    _send(Wire.roomSettings(mode.name));
  }

  @override
  Future<void> setRoomAutoplay(bool on) async {
    _inRoom();
    _send(Wire.autoplay(on));
  }

  @override
  Future<void> setSolo(bool on) async {
    final session = _inRoom();
    if (on) {
      session.goSolo();
    } else {
      session.rejoin();
    }
  }

  @override
  Future<void> keepPlaying() async {
    final session = _inRoom();
    session.goSolo();
    session.soloPlay();
  }

  @override
  Future<void> setTrim(int ms) async {
    await prefs.setInt(_keyTrim, ms);
    _session?.trimMs = ms;
  }

  // ------------------------------------------------------------------ transport and queue

  /// Runs the action for wherever the buttons act: outside a room (the personal queue), alone in a room, or on the room
  /// itself.
  void _act({
    required void Function() outside,
    required void Function(GroupSession s) alone,
    required String Function() inRoom,
  }) {
    final session = _session;
    if (session == null) {
      outside();
    } else if (session.isSolo) {
      alone(session);
    } else {
      _send(inRoom());
    }
  }

  /// The queue is the room's in a room, even while listening alone, and the personal one outside.
  void _onQueue({required void Function() outside, required String Function() inRoom}) {
    if (_session == null) {
      outside();
    } else {
      _send(inRoom());
    }
  }

  String? get _roomItemId => _session?.snapshot.state?.current?.id;

  @override
  Future<void> play() async {
    final session = _session;
    if (session == null) {
      _local.play();
    } else {
      final phase = session.snapshot.state?.phase;
      // This device could not load the room's song: load it again rather than press play on nothing
      if (phase == 'playing' && session.catchUp()) return;
      // Held back from outside while the room plays on: join the room where it is, not where the sound was lost
      if (!session.isSolo && phase == 'playing' && (session.isHeld || !player.isPlaying())) {
        session.resumeHere();
      } else {
        session.unhold();
        _act(outside: _local.play, alone: (s) => s.soloPlay(), inRoom: Wire.play);
      }
    }
    _emitPosition();
  }

  @override
  Future<void> pause() async {
    _act(outside: _local.pause, alone: (s) => s.soloPause(), inRoom: Wire.pause);
    _emitPosition();
  }

  @override
  Future<void> next() async =>
      _act(outside: _local.next, alone: (s) => s.soloNext(), inRoom: () => Wire.next(from: _roomItemId));

  @override
  Future<void> prev() async =>
      _act(outside: _local.prev, alone: (s) => s.soloPrev(), inRoom: () => Wire.prev(from: _roomItemId));

  @override
  Future<void> seek(int positionMs) async => _act(
    outside: () => _local.seek(positionMs),
    alone: (s) => s.soloSeek(positionMs),
    inRoom: () => Wire.seek(positionMs),
  );

  @override
  Future<void> jump(String itemId) async => _act(
    outside: () => _local.jump(itemId),
    alone: (s) => s.soloJump(itemId),
    inRoom: () => Wire.jump(itemId),
  );

  @override
  Future<void> add(Track track, {bool playNext = false}) => addMany([track], playNext: playNext);

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) async {
    final refs = [for (final t in tracks) TrackRef.of(t)];
    _onQueue(outside: () => _local.add(refs, next: playNext), inRoom: () => Wire.queueAddMany(refs, playNext: playNext));
  }

  @override
  Future<void> setRepeat(Repeat mode) async =>
      _onQueue(outside: () => _local.setRepeat(mode.name), inRoom: () => Wire.repeat(mode.name));

  @override
  Future<void> remove(String itemId) async =>
      _onQueue(outside: () => _local.remove(itemId), inRoom: () => Wire.queueRemove(itemId));

  @override
  Future<void> swap(String itemId, Track track) async => _onQueue(
    outside: () => _local.swap(itemId, TrackRef.of(track)),
    inRoom: () => Wire.queueSwap(itemId, TrackRef.of(track)),
  );

  @override
  Future<void> move(String itemId, int toIndex) async =>
      _onQueue(outside: () => _local.move(itemId, toIndex), inRoom: () => Wire.queueMove(itemId, toIndex));

  @override
  Future<void> clear() async => _onQueue(outside: _local.clear, inRoom: Wire.queueClear);

  @override
  Future<void> shuffle() async => _onQueue(outside: _local.shuffle, inRoom: Wire.queueShuffle);

  /// Shuffle as a mode. A server older than protocol 11 has none, so there it mixes the queue once, as it always did.
  @override
  Future<void> setShuffle(bool on) async {
    if (_session == null) {
      _local.setShuffle(on);
    } else if (_session?.snapshot.state?.shuffle == null) {
      if (on) _send(Wire.queueShuffle());
    } else {
      _send(Wire.shuffle(on));
    }
  }

  /// Faster or slower than normal, outside a room only: in one the speed keeps the phones in step.
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (_session != null) return;
    _speed = speed.clamp(0.25, 2.0);
    player.setSpeed(_speed);
    _lastKey = null;
    _emitState();
  }

  var _speed = 1.0;

  // ------------------------------------------------------------------ the personal queue

  Timer? _saveTimer;
  SavedQueue? _unsaved;

  /// The queue is written down a moment after it changed, not at every change: it can hold a thousand songs.
  void _persistQueue(SavedQueue saved) {
    _unsaved = saved;
    _saveTimer ??= Timer(const Duration(milliseconds: 400), _flushQueue);
  }

  void _flushQueue() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final saved = _unsaved;
    if (saved == null) return;
    _unsaved = null;
    prefs.setString(_keyLocalQueue, jsonEncode(saved.toJson()));
  }

  bool get _autoplayOn => prefs.getBool(_keyAutoplay) ?? true;

  /// The music carries on with songs like the last when the queue runs out.
  @override
  Future<void> setAutoplay(bool on) async => prefs.setBool(_keyAutoplay, on);

  /// Songs like [videoId] that are worth offering: what YouTube Music's radio lists, without the ones in [exclude] and
  /// without what is not music (mixes of hours, clips of seconds), up to [limit].
  Future<List<TrackRef>> _moreLike(String videoId, Set<String> exclude, int limit) =>
      _suggestions.after(videoId, exclude, limit);

  /// Songs added each time the queue runs out and the music carries on by itself.
  static const _autoplayCount = 5;

  /// Songs that follow one that was played on its own.
  static const _radioCount = 20;

  /// A queue that has grown long by carrying on is started afresh rather than filling up.
  static const _autoplayRestartAt = 150;

  var _autoplaying = false;

  /// The personal queue ran out. Unless the person turned it off, it carries on with songs like the last one, so the
  /// music does not just stop. Nothing happens in a room, or when they asked for something else in the meantime.
  void _autoplay(QueueEntry last) {
    if (!_autoplayOn || _session != null || _autoplaying) return;
    _autoplaying = true;
    () async {
      try {
        final more = await _moreLike(last.videoId, {for (final e in _local.snapshot.queue) e.videoId}, _autoplayCount);
        if (more.isEmpty || _session != null || !_local.snapshot.finished) return;
        _note("local: autoplay adds ${more.length} songs like '${last.title}'");
        if (_local.snapshot.queue.length > _autoplayRestartAt) _local.clear();
        _local.add(more, next: false);
      } on Object catch (e) {
        _note('local: autoplay found nothing: $e');
      } finally {
        _autoplaying = false;
      }
    }();
  }

  var _radioFor = 0;

  /// A song was started on its own, from a search or a shelf. Like YouTube Music, the queue fills with songs like it, so
  /// skipping works at once and the music carries on. Nothing is added when autoplay is off, in a room, or when the
  /// person has changed the queue by the time the songs arrive.
  @override
  Future<void> fillRadio(String videoId) async {
    final turn = ++_radioFor;
    if (!_autoplayOn || _session != null) return;
    try {
      // The song that was tapped comes first: on a slow network the two would share it
      while (_local.snapshot.loading) {
        await _local.changes.firstWhere((s) => !s.loading).timeout(const Duration(seconds: 30));
      }
      final more = await _moreLike(videoId, {videoId}, _radioCount);
      final queue = _local.snapshot.queue;
      if (turn != _radioFor || more.isEmpty || _session != null || queue.length != 1 || queue.first.videoId != videoId) return;
      _note('local: radio adds ${more.length} songs like $videoId');
      _local.add(more, next: false);
    } on Object catch (e) {
      _note('local: no radio for $videoId: $e');
    }
  }

  /// The room's queue ran out and the server asked this device for songs like the last one, as [_autoplay] does for the
  /// personal queue. Nothing is sent when the room has moved on by the time they arrive, or when none were found.
  Future<void> _fillRoom(AutoplayFillMessage ask) async {
    try {
      final queue = {for (final e in _session?.snapshot.state?.queue ?? const <QueueEntry>[]) e.videoId};
      final more = await _moreLike(ask.videoId, queue, _autoplayCount);
      if (more.isEmpty || _session?.snapshot.state?.epoch != ask.epoch) return;
      _note("sync: autoplay adds ${more.length} songs like '${ask.title}' to the room");
      // Marked as autoplay's, so the room keeps them apart from the songs its members chose
      _send(Wire.queueAddMany(more, auto: true));
    } on Object catch (e) {
      _note('sync: autoplay found nothing for the room: $e');
    }
  }

  // ------------------------------------------------------------------ chat and reactions

  @override
  Future<bool> sendChat(String text, String cid, {int? reply, ChatQuote? quote}) async {
    _inRoom();
    final group = _session?.snapshot;
    if (group?.state?.enc != true) return _send(Wire.chat(text, cid, reply: reply));
    // A sealed room: the words go sealed, with what they answer inside; without the secret there is nothing to send
    final room = _roomCode;
    final secret = room == null ? null : ChatCipher.decodeSecret(_secrets[room] ?? '');
    final you = group?.you;
    if (room == null || secret == null || you == null) return false;
    final sealed = await ChatCipher.sealMessage(secret, room, you, text, quote);
    return _send(Wire.chatSealed(sealed.ct, sealed.pv, cid, reply: reply));
  }

  @override
  Future<bool> enableEncryption() async {
    _inRoom();
    final group = _session?.snapshot;
    final room = _roomCode;
    if (group == null || room == null || group.state?.enc == true || group.state?.ownerId != group.you) return false;
    _keepSecret(room, ChatCipher.encodeSecret(ChatCipher.newSecret()));
    _emitState();
    return _send(Wire.roomEncrypt());
  }

  @override
  Future<String?> roomSecret() async => _roomCode == null ? null : _secrets[_roomCode];

  @override
  Future<bool> setRoomSecret(String room, String secret) async {
    if (ChatCipher.decodeSecret(secret) == null || !RegExp(r'^[A-Za-z0-9]{6}$').hasMatch(room)) return false;
    _keepSecret(room, secret);
    _emitState();
    // The chat shown again, now that it can be read
    if (room.toUpperCase() == _roomCode) {
      _chatWork = _chatWork.then((_) async {
        final log = _chatLog;
        if (log == null || room.toUpperCase() != _roomCode) return;
        _events.add(ChatEvent(room: room.toUpperCase(), messages: await _open(room.toUpperCase(), log), replace: true, more: null));
      });
    }
    return true;
  }

  @override
  Future<void> reactChat(int id, Reaction? reaction) async {
    _inRoom();
    _send(Wire.chatReact(id, reaction?.wire));
  }

  @override
  Future<bool> loadOlderChat(int before) async {
    _inRoom();
    return _send(Wire.chatBefore(before));
  }

  @override
  Future<void> readChat(int upTo) async {
    _inRoom();
    _send(Wire.chatReceipt(read: upTo));
  }

  @override
  Future<void> react(Reaction reaction, int count) async {
    _inRoom();
    _send(Wire.react(reaction.wire, count));
  }

  /// [messages] as the room sent them, with the words of sealed ones read when this device has the room's secret.
  Future<List<ChatMessage>> _open(String room, List<ChatMessage> messages) async {
    if (messages.every((m) => m.ct == null)) return messages;
    final secret = ChatCipher.decodeSecret(_secrets[room.toUpperCase()] ?? '');
    return [
      for (final m in messages)
        if (m.ct == null)
          m
        else
          (secret == null ? null : await ChatCipher.openMessage(secret, room, m)) ?? m.asLocked,
    ];
  }

  void _onChat(String room, ServerMessage message) {
    _chatWork = _chatWork.then((_) => _handleChat(room, message)).catchError((Object e) => _note('chat: $e'));
  }

  Future<void> _handleChat(String room, ServerMessage message) async {
    // Left, or in another room, while the message was being opened
    switch (message) {
      case ChatHistoryMessage():
        final kept = message.messages.length > _chatKept
            ? message.messages.sublist(message.messages.length - _chatKept)
            : message.messages;
        _chatLog = kept;
        _events.add(ChatEvent(room: room, messages: await _open(room, kept), replace: true, receipts: message.receipts, more: message.more));
        if (kept.isNotEmpty) _acknowledge(kept.last);
        if (_chatWhenReady == room) {
          _chatWhenReady = null;
          _events.add(OpenChatEvent(room));
        }
      case ChatPageMessage():
        // Not kept here: the screen holds the pages it asked for, and the log is only what a returning screen is given
        _events.add(ChatEvent(room: room, messages: await _open(room, message.messages), replace: false, older: true, more: message.more));
      case ChatMessageReceived():
        final log = [...?_chatLog, message.message];
        _chatLog = log.length > _chatKept ? log.sublist(log.length - _chatKept) : log;
        _events.add(ChatEvent(room: room, messages: await _open(room, [message.message]), replace: false));
        _acknowledge(message.message);
      case ChatUpdateMessage():
        final log = _chatLog;
        if (log == null) return;
        _chatLog = [for (final m in log) m.id == message.message.id ? message.message : m];
        _events.add(ChatEvent(room: room, messages: await _open(room, [message.message]), replace: false));
      case ChatReceiptsMessage():
        _events.add(ChatEvent(room: room, messages: const [], replace: false, receipts: message.receipts));
      case ReactMessage():
        _events.add(ReactionEvent(message.by, Reaction.parse(message.e), message.n));
      default:
        break;
    }
  }

  /// Tells the room that the chat has reached this device up to [last], so that the others see their message as delivered.
  void _acknowledge(ChatMessage last) {
    if (last.id <= _deliveredUpTo) return;
    _deliveredUpTo = last.id;
    // What this device wrote itself needs no word
    if (last.by != _session?.snapshot.you) _send(Wire.chatReceipt(delivered: last.id));
  }

  // ------------------------------------------------------------------ notices of the chat while the page is away

  static const _keyNotify = 'web.notify';
  static const _keyNotifyPreview = 'web.notifyPreview';
  static const _keyNotifyMutes = 'web.notifyMutes';

  @override
  Future<NotificationInfo> notifications() async {
    final port = push;
    final support = port?.support ?? PushSupport.none;
    if (port == null || support == PushSupport.none) return const NotificationInfo();
    final permission = port.permission;
    return NotificationInfo(
      supported: true,
      permission: permission,
      enabled: support == PushSupport.ready && permission == NoticePermission.granted && (prefs.getBool(_keyNotify) ?? false),
      preview: prefs.getBool(_keyNotifyPreview) ?? true,
      needsInstall: support == PushSupport.needsInstall,
      mutes: _readMutes(),
    );
  }

  @override
  Future<NotificationInfo> setNotifications(bool on) async {
    final port = push;
    if (port == null) return notifications();
    if (!on) {
      await prefs.setBool(_keyNotify, false);
      await port.unsubscribe();
      _roomClient?.setPush(null);
      return notifications();
    }
    // A page an iPhone keeps in a tab gets none, however it asks
    if (port.support != PushSupport.ready) return notifications();
    _requireSetUp();
    final sub = await port.subscribe(await _pushKey());
    await prefs.setBool(_keyNotify, sub != null);
    await _offerPush();
    return notifications();
  }

  @override
  Future<void> setNotificationPreview(bool on) async {
    await prefs.setBool(_keyNotifyPreview, on);
    await _offerPush();
  }

  @override
  Future<void> muteRoomNotifications(String code, int? until) async {
    final mutes = _readMutes();
    if (until == null) {
      mutes.remove(code);
    } else {
      mutes[code] = until;
    }
    await prefs.setString(_keyNotifyMutes, jsonEncode(mutes));
    if (code == _roomCode) await _offerPush();
  }

  /// The rooms kept quiet, and until when; those whose time has passed are let go.
  Map<String, int> _readMutes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final saved = jsonDecode(prefs.getString(_keyNotifyMutes) ?? '{}') as Map<String, dynamic>;
      return {
        for (final e in saved.entries)
          if (e.value is num && (e.value as num).toInt() > now) e.key: (e.value as num).toInt(),
      };
    } on Object {
      return {};
    }
  }

  /// The public key the server signs its pushes with; a server without one does not send them.
  Future<String> _pushKey() async {
    final http.Response reply;
    try {
      reply = await _http.get(Uri.parse('$_server/push/key'), headers: _authHeaders);
    } on Object {
      throw BackendException('failed', 'The server cannot be reached');
    }
    if (reply.statusCode == 401) {
      _keyRefused();
      throw BackendException('failed', 'The server turned the key down');
    }
    final key = reply.statusCode == 200 ? (jsonDecode(reply.body) as Map<String, dynamic>)['key'] : null;
    if (key is! String) throw BackendException('unsupported', 'This server sends no notifications');
    return key;
  }

  /// Tells the room's server what this browser wants of it, or that it wants nothing: sent when the person changes
  /// their mind and at every join.
  Future<void> _offerPush() async {
    final client = _roomClient;
    final code = _roomCode;
    if (client == null || code == null) return;
    if (!(prefs.getBool(_keyNotify) ?? false)) return client.setPush(null);
    final sub = await push?.current();
    // The person may have left the room while the browser answered
    if (sub == null || _roomClient != client) return;
    client.setPush(
      Wire.pushSet(
        sub,
        code,
        until: _readMutes()[code],
        preview: prefs.getBool(_keyNotifyPreview) ?? true,
        lang: _language,
      ),
    );
  }

  // ------------------------------------------------------------------ YouTube Music

  late final MusicFeed _feed = MusicFeed(MusicClient(_askYoutube, region: region), LyricsClient(_askLrclib));
  var _language = 'en';

  /// Asks YouTube Music through the room server, which a page cannot do itself.
  Future<String> _askYoutube(String endpoint, String body) async {
    _requireSetUp();
    final http.Response reply;
    try {
      reply = await _http.post(
        Uri.parse('$_server/yt/$endpoint'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: body,
      );
    } on Object {
      throw BackendException('failed', 'The server cannot be reached');
    }
    if (reply.statusCode == 401) {
      _keyRefused();
      throw BackendException('failed', 'The server turned the key down');
    }
    if (reply.statusCode != 200) {
      throw BackendException('failed', 'YouTube Music did not answer (${reply.statusCode})');
    }
    return utf8.decode(reply.bodyBytes);
  }

  /// Asks LRCLIB itself: it is open to any page, and takes no key, so the room server is not needed. No header is
  /// added, as a browser would then ask it for permission first.
  Future<String?> _askLrclib(String url) async {
    final reply = await _http.get(Uri.parse(url));
    if (reply.statusCode == 404) return null;
    if (reply.statusCode != 200) throw BackendException('failed', 'LRCLIB answered ${reply.statusCode}');
    return utf8.decode(reply.bodyBytes);
  }

  DateTime _keyRefusedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The server does not take the key: said once in a while, not at every request, as a page asks many at once.
  void _keyRefused() {
    final now = DateTime.now();
    if (now.difference(_keyRefusedAt) < const Duration(seconds: 20)) return;
    _keyRefusedAt = now;
    _events.add(ErrorEvent(const ServerError('key_refused', 'The room key was not accepted')));
  }

  /// This device's own picture as base64, shown to every room it is in.
  String? _avatar;

  @override
  Future<void> setAvatar(String? base64) async {
    _avatar = base64;
    _roomClient?.setAvatar(base64);
  }

  @override
  Future<void> setLanguage(String code) async => _language = code;

  bool get _video => prefs.getBool(_keyVideo) ?? false;

  /// Shows the frame of YouTube (video) or the cover (audio), on this browser; the sound is the same.
  @override
  Future<void> setVideoMode(bool on) async {
    await prefs.setBool(_keyVideo, on);
    _emitState();
  }

  /// Writes down what is still waiting for its moment (the queue, the library), for a page that is going away.
  Future<void> flush() async {
    _flushQueue();
    await _library.flush();
  }

  // ------------------------------------------------------------------ library

  @override
  Future<List<Track>> liked() async => _library.liked();

  @override
  Future<List<HistoryEntry>> recent() async => _library.recent();

  @override
  Future<List<HistoryEntry>> listens({int limit = 600}) async => _library.listens(limit: limit);

  @override
  Future<void> setLiked(Track track, bool liked) async => _library.setLiked(track, liked);

  @override
  Future<void> clearHistory() async => _library.clearHistory();

  @override
  Future<List<SavedPlaylist>> playlists() async => _library.playlists();

  @override
  Future<List<Track>> playlistTracks(int id) async => _library.playlistTracks(id);

  @override
  Future<List<PlaylistFolder>> folders() async => _library.folders();

  @override
  Future<int> createFolder(String name) async => _library.createFolder(name);

  @override
  Future<void> renameFolder(int id, String name) async => _library.renameFolder(id, name);

  @override
  Future<void> deleteFolder(int id) async => _library.deleteFolder(id);

  @override
  Future<void> setPlaylistFolder(int id, int? folderId) async => _library.setPlaylistFolder(id, folderId);

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async => _library.createPlaylist(name, tracks);

  @override
  Future<void> renamePlaylist(int id, String name) async => _library.renamePlaylist(id, name);

  @override
  Future<void> deletePlaylist(int id) async => _library.deletePlaylist(id);

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async => _library.addToPlaylist(id, tracks);

  @override
  Future<void> removeFromPlaylist(int id, String videoId) async => _library.removeFromPlaylist(id, videoId);

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) async => _library.movePlaylistItem(id, videoId, toIndex);

  @override
  Future<void> share(String text) async => onShare?.call(text);

  // ------------------------------------------------------------------ what the person likes: suggestions, blocks

  late final SuggestionFeed _suggestions = SuggestionFeed(
    store: _library,
    radio: (videoId) async => [for (final t in (await _feed.watchNext(videoId)).tracks) TrackRef.of(t)],
    log: (line) => _note('suggestions: $line'),
  );

  static Track _track(TrackRef t) => Track(videoId: t.videoId, title: t.title, artist: t.artist, thumb: t.thumb, durMs: t.durMs);

  @override
  Future<List<Track>> forYou() async => [for (final t in _suggestions.forYou()) _track(t)];

  @override
  Future<List<Track>> refreshSuggestions() async {
    await _suggestions.renew(force: true);
    return forYou();
  }

  @override
  Future<List<SeedList>> seedLists() async => [
    for (final (seed, tracks) in _suggestions.seedLists()) SeedList(seed: seed, tracks: [for (final t in tracks) _track(t)]),
  ];

  @override
  Future<List<Track>> discover() async => [for (final t in _suggestions.discover()) _track(t)];

  @override
  Future<ContextMix> contextMix() async {
    final (bucket, tracks) = await _suggestions.contextMix();
    return ContextMix(bucket: bucket, tracks: [for (final t in tracks) _track(t)]);
  }

  /// A song is blocked by its video id, an artist by the name of the first artist credited.
  @override
  Future<void> block(Track track, {bool artistOnly = false}) async {
    if (artistOnly) {
      _library.block(SuggestionFeed.artist, Taste.artistKey(track.artist), Taste.artistLabel(track.artist));
    } else {
      _library.block(SuggestionFeed.song, track.videoId, track.title);
    }
  }

  @override
  Future<void> unblock(BlockedItem item) async => _library.unblock(item.kind, item.key);

  @override
  Future<List<BlockedItem>> blocked() async => _library.blocked();

  DateTime? _renewedAt;

  /// Brings the suggestions up to date when the page opens, at most twice an hour: they are shown from what was kept, so
  /// there is no hurry.
  void _renewSuggestionsIfDue() {
    final now = DateTime.now();
    final last = _renewedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 30)) return;
    if (_server.isEmpty || _key.isEmpty) return;
    _renewedAt = now;
    _suggestions.renew(force: false).ignore();
  }

  // ------------------------------------------------------------------ sleep timer

  /// Stops this device after a while, or when the song is over; the fade is the player's own volume.
  late final SleepTimer _sleep = SleepTimer(
    wallClock: () => DateTime.now().millisecondsSinceEpoch,
    stop: _stopForSleep,
    fade: player.setVolume,
    pauseAtSongEnd: player.pauseAtEnd,
    onChanged: (state) => _events.add(SleepEvent(state)),
  );

  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) async {
    switch (mode) {
      case SleepMode.time:
        _sleep.startIn(minutes);
      case SleepMode.song:
        _sleep.startAtSongEnd();
      case SleepMode.off:
        _sleep.cancel();
    }
  }

  /// The sleep timer ran out. In a room only this device stops: it carries on alone, paused, and the room plays on.
  void _stopForSleep() {
    final session = _session;
    if (session == null) {
      _local.pause();
      return;
    }
    if (!session.isSolo) session.goSolo();
    session.soloPause();
  }

  // ------------------------------------------------------------------ picture quality

  int get _videoHeight => prefs.getInt(_keyVideoHeight) ?? _defaultVideoHeight;

  /// What a frame of YouTube is asked for until the person says otherwise: the lowest it goes.
  static const _defaultVideoHeight = 480;

  /// The size the picture is fetched at, from the next song on, or as soon as the frame is shown larger.
  @override
  Future<void> setVideoQuality(int height) async {
    await prefs.setInt(_keyVideoHeight, height);
    player.setVideoHeight(height);
    _emitState();
  }

  /// Up to [limit] songs or, without [songsOnly], videos matching [query]. The apps read the whole of YouTube for
  /// videos; here it is what YouTube Music lists under Videos.
  @override
  Future<List<Track>> search(String query, {bool songsOnly = false, int? limit}) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    return _feed.tracks(text, songs: songsOnly, limit: limit ?? _searchLimit);
  }

  static const _searchLimit = 20;

  /// Completions of a half-typed search; empty when YouTube Music cannot be reached, since they are only a help.
  @override
  Future<List<String>> suggest(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    try {
      return (await _feed.suggestions(text)).take(_suggestionLimit).toList();
    } on BackendException {
      return const [];
    }
  }

  static const _suggestionLimit = 8;

  /// Turns pasted text into tracks: a playlist link gives its songs, a video link (or a bare video id) gives one
  /// song, anything else gives null. A song is read off its own radio, where it comes first.
  @override
  Future<LinkResult?> lookup(String text) async {
    final trimmed = text.trim();
    final list = YoutubeLinks.playlistId(trimmed);
    if (list != null) {
      final page = await _feed.collection(list);
      final tracks = [...page.tracks];
      var more = page.more;
      while (more != null && tracks.length < _playlistLimit) {
        final next = await _feed.more(more);
        tracks.addAll(next.tracks);
        more = next.more;
      }
      return LinkResult(
        tracks: tracks.length > _playlistLimit ? tracks.sublist(0, _playlistLimit) : tracks,
        playlistTitle: page.title,
      );
    }
    final id = YoutubeLinks.videoId(trimmed);
    if (id == null) return null;
    final song = (await _feed.watchNext(id)).tracks.where((t) => t.videoId == id).firstOrNull;
    if (song == null) throw BackendException('failed', 'YouTube Music has nothing for this video');
    return LinkResult(tracks: [song]);
  }

  static const _playlistLimit = 50;

  @override
  Future<List<MusicTrack>> musicSearch(String query, {required bool songs}) =>
      _feed.tracks(query.trim(), songs: songs, limit: _searchLimit);

  @override
  Future<SongRadio> musicNext(String videoId) async {
    final next = await _feed.watchNext(videoId);
    return SongRadio(tracks: next.tracks, hasLyrics: next.lyricsId != null, hasRelated: next.relatedId != null);
  }

  @override
  Future<RelatedPage> musicRelated(String videoId) async {
    final related = await _feed.related(videoId);
    if (related == null) return const RelatedPage();
    return RelatedPage(
      more: related.more,
      otherPerformances: related.otherPerformances,
      artists: related.artists,
      playlists: related.playlists,
      about: related.about,
    );
  }

  @override
  Future<ArtistPage> musicArtist(String artistId) => _feed.artist(artistId);

  @override
  Future<CollectionPage> musicCollection(String id) => _feed.collection(id);

  @override
  Future<MoreTracks> musicMore(String token) => _feed.more(token);

  @override
  Future<SearchResults> musicSearchPage(String query, {String? params}) => _feed.searchPage(query.trim(), params);

  @override
  Future<SearchResults> musicSearchMore(String token) => _feed.searchMore(token);

  @override
  Future<List<MusicShelf>> musicTrending() => _feed.trending(_language);

  @override
  Future<MusicHome> musicHome({String? params}) => _feed.home(_language, params);

  @override
  Future<List<MusicShelf>> musicCharts() => _feed.charts();

  @override
  Future<Lyrics?> lyrics(Track track) => _feed.lyrics(track.videoId, track.title, track.artist, track.durMs ~/ 1000);

  // ------------------------------------------------------------------ what the screen is told

  void _onSessionEvent(RoomEvent event) {
    String nameOf(String id) {
      for (final m in _session?.snapshot.members ?? const <Member>[]) {
        if (m.id == id) return m.name;
      }
      return '';
    }

    switch (event) {
      case PausedEvent():
        _events.add(NoticeEvent(kind: 'paused', by: nameOf(event.byId)));
      case SkippedEvent():
        _events.add(NoticeEvent(kind: 'skipped', by: nameOf(event.byId), title: event.title));
      case LoadFailedEvent():
        // Told as the personal queue tells it: the person may be the only one not hearing the song
        final code = switch (event.reason) {
          LoadReason.offline => 'load_offline',
          LoadReason.unplayable => 'load_unplayable',
          null => 'load_failed',
        };
        _events.add(ErrorEvent(ServerError(code, event.title)));
    }
  }

  String? _lastKey;

  RoomSnapshot _snapshot() {
    final group = _session?.snapshot;
    final state = group?.state;
    final local = _local.snapshot;
    final inRoom = _roomCode != null;
    return RoomSnapshot(
      room: _roomCode,
      link: switch (_connection) {
        null => Link.none,
        Connection.connecting => Link.connecting,
        Connection.connected => Link.connected,
        Connection.reconnecting => Link.reconnecting,
        Connection.closed || Connection.refused => Link.closed,
        Connection.unauthorized => Link.unauthorized,
      },
      you: group?.you,
      // Outside a room whether it plays is the player's business; this only says whether there is something to play
      phase: inRoom ? state?.phase ?? 'idle' : (local.queue.isEmpty || local.finished ? 'idle' : 'paused'),
      index: inRoom ? state?.index ?? 0 : local.index,
      repeat: Repeat.parse(inRoom ? state?.repeat : local.repeat),
      queue: inRoom ? state?.queue ?? const [] : local.queue,
      members: group?.members ?? const [],
      trimMs: prefs.getInt(_keyTrim) ?? 0,
      solo: group?.solo ?? false,
      soloItemId: group?.soloItemId,
      // A song is on its way to play on this device: outside a room, or while listening alone in one
      loading: inRoom ? group?.loading ?? false : local.loading,
      // Audio is the way of every other device: the cover. Video shows the frame of YouTube in its place
      video: _video,
      videoHeight: _videoHeight,
      playbackSpeed: inRoom ? 1 : _speed,
      name: state?.name,
      ownerId: state?.ownerId,
      theme: inRoom ? state?.theme : null,
      guestControl: GuestControl.parse(state?.guestControl),
      roomAutoplay: state?.autoplay,
      encrypted: inRoom && state?.enc == true,
      encryptionKey: inRoom && _secrets.containsKey(_roomCode),
      // Outside a room this device's own; in one the room's, or null on a server too old to have it
      shuffle: inRoom ? state?.shuffle : local.shuffle,
    );
  }

  void _emitState() {
    final snapshot = _snapshot();
    // Drift and speed change all the time and are not part of what the screen draws
    final key = [
      snapshot.room,
      snapshot.link,
      snapshot.you,
      snapshot.phase,
      snapshot.index,
      snapshot.repeat,
      snapshot.queue.map((e) => e.id).join(','),
      snapshot.members.map((m) => '${m.id}${m.name}${m.ready}${m.solo}${m.away}${m.owner}').join(','),
      snapshot.solo,
      snapshot.soloItemId,
      snapshot.loading,
      snapshot.name,
      snapshot.ownerId,
      snapshot.theme,
      snapshot.guestControl,
      snapshot.roomAutoplay,
      snapshot.shuffle,
      snapshot.encrypted,
      snapshot.encryptionKey,
      snapshot.trimMs,
      snapshot.playbackSpeed,
      snapshot.video,
      snapshot.videoHeight,
    ].join('|');
    if (key == _lastKey) return;
    _lastKey = key;
    _events.add(StateEvent(snapshot));
    _emitPosition();
  }

  String? _shownOutside;

  void _tellBrowser(QueueEntry? item, bool playing) {
    final media = this.media;
    if (media == null) return;
    final key = '${item?.id}|$playing';
    if (key == _shownOutside) return;
    _shownOutside = key;
    media.update(title: item?.title, artist: item?.artist, artwork: item?.thumb, playing: playing);
  }

  /// The song this device plays now: in a room the room's, or the one it listens to alone.
  QueueEntry? _playingNow() {
    final group = _session?.snapshot;
    final state = group?.state;
    return _session == null
        ? _local.snapshot.current
        : group?.solo == true
        ? state?.queue.where((e) => e.id == group?.soloItemId).firstOrNull
        : state?.current;
  }

  /// Hands the listening to the tracker, which says when a song has been heard long enough for the history.
  void _watchListening(QueueEntry? item, bool playing) {
    final now = _now();
    // A song loaded again (repeat one) is a new listen, so only the song's id tells that it is another
    if (item?.videoId != _listened?.videoId) {
      _listens.begin(item?.videoId, player.durationMs() > 0 ? player.durationMs() : item?.durMs ?? 0, now);
      _listened = item;
    }
    if (item != null) {
      _listens.setDuration(player.durationMs());
      _listens.setPlaying(playing, now);
      _listens.check(now);
    }
  }

  /// A song was left after a few seconds, before it counted: the person did not want it, which the taste takes in.
  void _skipped(String id, int durationMs) {
    final item = _listened;
    if (item == null || item.videoId != id) return;
    _library.recordSkip(
      Track(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs > 0 ? durationMs : item.durMs),
    );
  }

  void _heard(String id, int durationMs) {
    final item = _listened;
    if (item == null || item.videoId != id) return;
    _library.recordListen(
      Track(videoId: id, title: item.title, artist: item.artist, thumb: item.thumb, durMs: durationMs > 0 ? durationMs : item.durMs),
    );
  }

  void _emitPosition() {
    final group = _session?.snapshot;
    final state = group?.state;
    final session = _session;
    final item = _playingNow();
    final playing = player.isPlaying();
    _watchListening(item, playing);
    if (!_events.hasListener) return;
    _tellBrowser(item, playing);
    // After a restart nothing is loaded yet, and the song shows where it will resume
    final restored = session == null ? _local.restoredPositionMs : null;
    _events.add(
      PositionEvent(
        PlayerPosition(
          playing: playing,
          buffering: player.isBuffering(),
          positionMs: restored ?? player.positionMs(),
          durationMs: player.durationMs() > 0 ? player.durationMs() : (item?.durMs ?? 0),
          driftMs: group?.driftMs,
          speed: group?.speed ?? (session == null ? _speed : 1),
          // Held back: the room plays on, this device is silent
          heldBack:
              session != null &&
              !session.isSolo &&
              state?.phase == 'playing' &&
              (session.isHeld || (session.isInSync && !playing)),
        ),
      ),
    );
  }
}

