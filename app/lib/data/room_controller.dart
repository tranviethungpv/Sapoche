import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../strings.dart';
import 'backend.dart';
import 'calm.dart';
import 'invite_secret.dart';
import 'models.dart';
import 'recent_rooms.dart';
import 'setup_link.dart';
import 'song_key.dart';

/// How many songs a queue holds: a room's is what the server keeps (`MAX_QUEUE` in `server/src/room.ts`), the one outside
/// a room is larger (`LocalSession.MAX_QUEUE` in Kotlin, `maxQueue` in Swift). A song past it is not taken.
int queueMax({required bool inRoom}) => inRoom ? 200 : 1000;

/// How many songs the server takes from one `queue.addMany`; more are sent in several.
const _serverAddMany = 100;

/// The room protocol this app expects of the server (`PROTOCOL_VERSION` in `server/src/protocol.ts`). Raise it when the
/// app needs something that older servers lack; the check in Settings > Server says when the server is behind.
const serverProtocolNeeded = 17;

/// How many songs of a list on the screen have their streams looked up ahead, see [RoomController.warmUp].
const _warmCount = 3;

/// `key=` in the address of a room, `#key=` in a setup link, `#k=` in an invitation.
final _secretInLink = RegExp(r'([?&#](?:key|k)=)[^&#\s]+');

/// Something another member did that moved this device: worth a snackbar, sometimes with a way out.
class Notice {
  const Notice(
    this.text, {
    this.canKeepPlaying = false,
    this.opensChat = false,
  });

  final String text;

  /// The room paused and this device may prefer to go on alone.
  final bool canKeepPlaying;

  /// A message came in the room's chat, which is not open.
  final bool opensChat;
}

/// A reaction to show: [name] reacted with [reaction], [count] taps of it. [mine] when it is this device's own.
class RoomReaction {
  const RoomReaction({
    required this.name,
    required this.reaction,
    this.count = 1,
    this.mine = false,
  });

  final String name;
  final Reaction reaction;
  final int count;
  final bool mine;
}

/// A reaction of somebody that nothing showed when it came.
class _Unseen {
  const _Unseen(this.by, this.reaction, this.count, this.at);

  final String by;
  final Reaction reaction;
  final int count;

  /// On the controller's clock.
  final Duration at;
}

/// The room as the UI sees it: latest state from the native side plus the actions a user can take.
///
/// Room structure notifies listeners rarely; the player position lives in [player] and is
/// extrapolated by [positionMs], so nothing has to rebuild sixty times a second.
class RoomController extends ChangeNotifier {
  RoomController(this._backend, {this._recents}) {
    player.addListener(_updatePlayState);
    addListener(_updatePlayState);
    playState.addListener(_updateWatching);
  }

  final Backend _backend;
  final RecentRooms? _recents;
  StreamSubscription<BackendEvent>? _subscription;

  RoomSnapshot _snapshot = const RoomSnapshot();
  SleepState _sleep = const SleepState();
  AudioOutput _output = const AudioOutput();

  /// The volume of the device, 0 to 1; moves with its buttons too.
  final volume = ValueNotifier<double>(1);

  /// The pictures the other members chose, by member id.
  final _avatars = <String, Uint8List>{};
  Profile _profile = const Profile();
  bool _ready = false;

  /// Local player state, updated about once a second while the screen is on.
  final ValueNotifier<PlayerPosition> player = ValueNotifier(
    const PlayerPosition(),
  );
  final Stopwatch _sinceSample = Stopwatch();

  /// [isPlaying] and [isStarting], told only when one of them changes: for what shows a play button or moves while a
  /// song plays. Listening to [player] instead draws the screen again at every position the phone sends, for nothing.
  final ValueNotifier<(bool playing, bool starting)> playState = ValueNotifier((
    false,
    false,
  ));

  void _updatePlayState() => playState.value = (isPlaying, isStarting);

  /// While the user's seek is in flight the bar stays where they dropped it.
  int? _seekTarget;
  Timer? _seekTimer;

  /// The last [playTracks] outside a room; the next one waits for it.
  Future<void> _replacing = Future.value();

  /// A room code from an invitation link that the UI has not dealt with yet.
  final ValueNotifier<String?> invite = ValueNotifier(null);

  /// A setup link that was opened, for the screen to check and ask about.
  final ValueNotifier<SetupLink?> setup = ValueNotifier(null);

  /// The app is shown in a small window over other apps, where only the picture belongs.
  final ValueNotifier<bool> pictureInPicture = ValueNotifier(false);

  /// Goes up each time the person touches a notice of the chat of the room they are in: the chat is what they want.
  final ValueNotifier<int> chatRequests = ValueNotifier(0);

  /// The chat is on the screen. There is one chat at a time: a touch on a notice (or ten at once, from the notices
  /// the phone gathered into one) while it is shown asks for nothing more.
  bool chatSheetShown = false;

  NotificationInfo _noticeInfo = const NotificationInfo();

  /// Whether, and how, the person is told of the chat while the app is away.
  NotificationInfo get notificationInfo => _noticeInfo;

  /// Until when the room the person is in is quiet, or null when it is not.
  DateTime? get roomMutedUntil => _noticeInfo.mutedUntil(_snapshot.room);

  bool _pipSupported = false;

  /// The phone can show the picture in a small window over other apps.
  bool get pipSupported => _pipSupported;

  final _messages = StreamController<String>.broadcast();
  final _notices = StreamController<Notice>.broadcast();

  /// What other members did to this device, see [Notice].
  Stream<Notice> get notices => _notices.stream;

  /// While listening alone, what the play button shows right after a tap, before the player reports back.
  bool? _soloPlaying;

  /// Short notices for a snackbar: server errors, failed actions.
  Stream<String> get messages => _messages.stream;

  RoomSnapshot get snapshot => _snapshot;

  /// When the music is set to stop by itself.
  SleepState get sleep => _sleep;

  /// Where the sound goes now.
  AudioOutput get output => _output;

  /// The picture a member chose, or null when they have none.
  Uint8List? avatarOf(String memberId) => _avatars[memberId];

  /// What the picture behind the chat is asked for as, and comes back as: no member's id looks like it.
  static const backgroundId = 'room:bg';

  /// The room the picture behind the chat was last received for.
  String? _backgroundRoom;

  /// The picture the room has put behind its chat; null if it has none.
  Uint8List? get background =>
      _snapshot.inRoom && _backgroundRoom == _snapshot.room
      ? _avatars[backgroundId]
      : null;
  Profile get profile => _profile;

  /// False until the first state arrived from the native side.
  bool get ready => _ready;

  Future<void> start() async {
    _subscription = _backend.events.listen(_onEvent);
    try {
      _profile = await _backend.profile();
    } on Object {
      // The name field just starts empty
    }
    try {
      _pipSupported = await _backend.pictureInPictureSupported();
    } on Object {
      // No small window then
    }
    await _refreshNotices();
    await _readGroupKey();
    notifyListeners();
  }

  Future<void> _refreshNotices() async {
    try {
      _noticeInfo = await _backend.notifications();
    } on Object {
      // The device does not say: it has none
    }
  }

  void _onEvent(BackendEvent event) {
    switch (event) {
      case StateEvent(:final snapshot):
        if (snapshot.ownPlayback != _snapshot.ownPlayback) _soloPlaying = null;
        final code = snapshot.room;
        if (code != null) _recents?.touch(code, name: snapshot.name);
        _snapshot = snapshot;
        _syncSecret(snapshot);
        // The chat belongs to its room: out of it, or in another one, it is gone
        if (_chatRoom != null && code != _chatRoom) _forgetChat();
        // A picture is kept while its owner is in the room
        _avatars.removeWhere(
          (id, _) => id == backgroundId
              ? code == null
              : !snapshot.members.any((m) => m.id == id),
        );
        _ready = true;
        notifyListeners();
        _updateWatching();
      case NoticeEvent(:final kind, :final by, :final title):
        final who = by.isEmpty ? S.someone : by;
        if (kind == 'paused') {
          _notices.add(Notice(S.pausedBy(who), canKeepPlaying: true));
        } else if (kind == 'skipped') {
          _notices.add(Notice(S.skippedBy(who, title ?? '')));
        }
      case PositionEvent(:final position):
        _soloPlaying = null;
        _sinceSample
          ..reset()
          ..start();
        player.value = position;
        _updateWatching();
      case InviteEvent(:final code):
        invite.value = code;
      case OpenChatEvent(:final room):
        // In that room the chat opens; out of it, or in another, the room is offered like an invitation
        if (room == _snapshot.room) {
          chatRequests.value++;
        } else {
          invite.value = room;
        }
      case SetupEvent(:final link):
        // A link that is not one is ignored, as is any other thing that is opened
        final parsed = SetupLink.parse(link);
        if (parsed != null) setup.value = parsed;
      case SleepEvent(:final sleep):
        _sleep = sleep;
        notifyListeners();
      case ChatEvent(
        :final room,
        :final messages,
        :final replace,
        :final receipts,
        :final older,
        :final more,
      ):
        _onChat(room, messages, replace, receipts, older: older, more: more);
      case ReactionEvent(
        :final by,
        reaction: final reaction?,
        :final count,
        :final late,
      ):
        if (late || _reactionWatchers == 0) {
          // Nothing shows them now, or they are already over: they are shown, a few, when something does
          _unseen.add(_Unseen(by, reaction, count, _clock.elapsed));
          if (_unseen.length > maxUnseenReactions) _unseen.removeAt(0);
          if (_reactionWatchers > 0) _showUnseenSoon();
        } else {
          _reactions.add(
            RoomReaction(
              name: _snapshot.nameOf(by),
              reaction: reaction,
              count: count,
            ),
          );
        }
      case ReactionEvent():
        break; // one a newer app sent, which this one cannot show
      case AvatarEvent(:final id, :final bytes):
        if (id == backgroundId) _backgroundRoom = _snapshot.room;
        if (bytes == null) {
          _avatars.remove(id);
        } else {
          _avatars[id] = bytes;
        }
        notifyListeners();
      case OutputEvent(:final output):
        _output = output;
        notifyListeners();
      case VolumeEvent(:final level):
        volume.value = level;
      case LibraryEvent():
        break; // LibraryController listens for this itself
      case UpdateEvent():
        break; // and UpdateController for this
      case CalmEvent(:final on, :final weak):
        Calm.weak = weak;
        Calm.warm = on;
      case PipEvent(:final on):
        pictureInPicture.value = on;
      case ErrorEvent(:final error):
        final text = _describe(error);
        if (text != null) _messages.add(text);
    }
  }

  // ------------------------------------------------------------------ chat and reactions

  /// The room's chat, oldest first, with this device's own messages that the room has not confirmed yet at the end.
  final ValueNotifier<List<ChatMessage>> chat = ValueNotifier(const []);

  /// Messages of the others that came while the chat was not open.
  final ValueNotifier<int> unreadChat = ValueNotifier(0);

  /// What each member has got of the chat, by their id: how far a message of this device has come.
  final ValueNotifier<Map<String, ChatReceipt>> receipts = ValueNotifier(
    const {},
  );

  /// The room whose chat [chat] holds: null outside a room, or in one whose server is too old to keep a chat.
  String? _chatRoom;

  /// Whether the room keeps messages from before the oldest of [chat], to be read by [loadOlderChat].
  final ValueNotifier<bool> chatHasOlder = ValueNotifier(false);

  /// When a page of older messages was asked for and has not come yet; null when none is on its way.
  DateTime? _olderAskedAt;

  /// The last message the person has seen, by the room's number for it.
  int _readUpTo = 0;

  /// The last message the room was told has been looked at.
  int _readTold = 0;
  bool _chatOpen = false;
  int _chatSequence = 0;

  /// For each message on its way, the moment it is given up on.
  final _chatDeadlines = <String, Timer>{};

  final _reactions = StreamController<RoomReaction>.broadcast();

  /// Reactions to show as they come, this device's own included.
  Stream<RoomReaction> get reactions => _reactions.stream;

  /// How many places show the reactions flying right now (the player, the chat, the emoji sheet).
  int _reactionWatchers = 0;

  /// What came while none did, or while the screen was off.
  final _unseen = <_Unseen>[];
  final _lateTimers = <Timer>[];
  final _clock = Stopwatch()..start();

  /// Most reactions kept for a place that shows them later; the oldest go.
  static const maxUnseenReactions = 100;

  /// Reactions older than this are not worth showing any more.
  static const unseenKept = Duration(minutes: 5);

  /// What is shown of the ones missed: each member's taps on each emoji, at most this many taps, in this many emoji.
  static const lateTaps = 3;
  static const lateKinds = 12;

  /// A place that shows reactions flying has come, or gone. When the first one comes, the ones missed are shown.
  void watchReactions() {
    if (_reactionWatchers++ == 0 && _unseen.isNotEmpty) _showUnseenSoon();
  }

  void unwatchReactions() => _reactionWatchers--;

  /// After the place has begun to appear, so that they are seen from the start.
  void _showUnseenSoon() {
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 300), () {
      _lateTimers.remove(timer);
      _showUnseen();
    });
    _lateTimers.add(timer);
  }

  void _showUnseen() {
    final from = _clock.elapsed - unseenKept;
    final sums = <(String, Reaction), int>{};
    for (final seen in _unseen) {
      if (seen.at < from) continue;
      sums.update(
        (seen.by, seen.reaction),
        (taps) => taps + seen.count,
        ifAbsent: () => seen.count,
      );
    }
    _unseen.clear();
    // The latest kinds, one after another so they do not all start at once
    final shown = sums.entries.toList();
    final latest = shown.sublist(
      shown.length > lateKinds ? shown.length - lateKinds : 0,
    );
    for (var i = 0; i < latest.length; i++) {
      final MapEntry(key: (by, reaction), value: taps) = latest[i];
      late final Timer timer;
      timer = Timer(Duration(milliseconds: 140 * i), () {
        _lateTimers.remove(timer);
        if (_reactions.isClosed) return;
        _reactions.add(
          RoomReaction(
            name: _snapshot.nameOf(by),
            reaction: reaction,
            count: taps < lateTaps ? taps : lateTaps,
          ),
        );
      });
      _lateTimers.add(timer);
    }
  }

  /// Taps on each reaction not sent yet; quick taps go together in one message.
  final _reactionTaps = <Reaction, int>{};
  Timer? _reactionFlush;

  /// The room can carry a chat and reactions: its server keeps them (protocol 10 or newer).
  bool get hasChat => _chatRoom != null && _chatRoom == _snapshot.room;

  /// A message of this device that the room has not confirmed in this long is shown as not sent.
  static const chatDeliveryTimeout = Duration(seconds: 10);

  /// Quick taps on reactions within this long go to the room as one message.
  static const reactionGathering = Duration(milliseconds: 400);

  /// The most taps one reaction message carries, as the room accepts.
  static const maxReactionCount = 10;

  /// The longest message the room keeps, in characters.
  static const maxChatChars = 500;

  void _onChat(
    String room,
    List<ChatMessage> messages,
    bool replace,
    Map<String, ChatReceipt>? told, {
    bool older = false,
    bool? more,
  }) {
    final had = hasChat;
    var list = chat.value;
    if (older) {
      if (room != _chatRoom) return;
      _olderAskedAt = null;
      // Above the first message of the room that is shown, whatever the page repeats of what is there already
      final shown = {
        for (final m in list)
          if (m.delivery == ChatDelivery.sent) m.id,
      };
      list = [
        for (final m in messages)
          if (!shown.contains(m.id)) m,
        ...list,
      ];
    } else if (replace) {
      if (room != _chatRoom) {
        // Arriving in a room: what was said before is there to read, not news
        _forgetChat();
        _chatRoom = room;
        _readUpTo = messages.isEmpty ? 0 : messages.last.id;
        list = const [];
      }
      final arrived = {for (final m in messages) ?m.cid};
      for (final cid in arrived) {
        _chatDeadlines.remove(cid)?.cancel();
      }
      list = [
        ...messages,
        for (final m in list)
          if (m.delivery != ChatDelivery.sent && !arrived.contains(m.cid)) m,
      ];
    } else {
      if (room != _chatRoom) return;
      list = [...list];
      for (final message in messages) {
        final known = list.indexWhere(
          (m) => m.delivery == ChatDelivery.sent && m.id == message.id,
        );
        if (known >= 0) {
          // Somebody reacted to it
          list[known] = message;
          continue;
        }
        // A reaction to a message from further back than the ones shown: it comes with the page that has the message
        final oldest = _oldestShown(list);
        if (message.cid == null && oldest != null && message.id < oldest) {
          continue;
        }
        final cid = message.cid;
        if (cid != null) {
          _chatDeadlines.remove(cid)?.cancel();
          list.removeWhere(
            (m) => m.delivery != ChatDelivery.sent && m.cid == cid,
          );
        }
        // Before this device's own that are still on their way
        final at = list.indexWhere((m) => m.delivery != ChatDelivery.sent);
        list.insert(at < 0 ? list.length : at, message);
        if (!_chatOpen && message.by != _snapshot.you) {
          _notices.add(
            Notice(S.chatFrom(message.name, message.text), opensChat: true),
          );
        }
      }
    }
    chat.value = list;
    if (more != null && room == _chatRoom) chatHasOlder.value = more;
    if (told != null && room == _chatRoom) receipts.value = told;
    _countUnread();
    if (hasChat != had) notifyListeners();
  }

  /// The number of the oldest message the room has confirmed in [list]; null when there is none.
  int? _oldestShown(List<ChatMessage> list) {
    for (final m in list) {
      if (m.delivery == ChatDelivery.sent) return m.id;
    }
    return null;
  }

  /// Asks the room for the messages before the oldest shown; they are put above it when they come. Nothing while one
  /// page is on its way (for as long as a message is waited for), or when the room has no older ones.
  Future<void> loadOlderChat() async {
    if (!hasChat || !chatHasOlder.value) return;
    final asked = _olderAskedAt;
    if (asked != null && DateTime.now().difference(asked) < chatDeliveryTimeout) {
      return;
    }
    final oldest = _oldestShown(chat.value);
    if (oldest == null) return;
    _olderAskedAt = DateTime.now();
    final sent = await _backend.loadOlderChat(oldest).catchError((_) => false);
    // With no connection the person can pull again at once
    if (!sent) _olderAskedAt = null;
  }

  void _countUnread() {
    final sent = chat.value.where((m) => m.delivery == ChatDelivery.sent);
    if (_chatOpen && sent.isNotEmpty) _readUpTo = sent.last.id;
    unreadChat.value = sent
        .where((m) => m.id > _readUpTo && m.by != _snapshot.you)
        .length;
    // The others are told what the person has looked at, which only the open chat shows them
    if (_chatOpen && hasChat && sent.isNotEmpty && sent.last.id > _readTold) {
      _readTold = sent.last.id;
      _run(() => _backend.readChat(_readTold));
    }
  }

  void _forgetChat() {
    for (final timer in _chatDeadlines.values) {
      timer.cancel();
    }
    _chatDeadlines.clear();
    _chatRoom = null;
    chatHasOlder.value = false;
    _olderAskedAt = null;
    _readUpTo = 0;
    _readTold = 0;
    chat.value = const [];
    receipts.value = const {};
    unreadChat.value = 0;
  }

  /// The chat is on screen ([open]) or no longer: while it is, what comes in counts as read.
  void setChatOpen(bool open) {
    _chatOpen = open;
    // Closing changes nothing that shows: everything was read while it was open
    if (open) _countUnread();
  }

  /// Writes [text] to the room's chat, as an answer to [reply] when given. It shows at once, and as not sent if the room
  /// does not confirm it.
  Future<void> sendChat(String text, {ChatQuote? reply}) async {
    final clean = text.trim();
    if (clean.isEmpty || !hasChat) return;
    final cid = '${DateTime.now().microsecondsSinceEpoch}-${_chatSequence++}';
    chat.value = [
      ...chat.value,
      ChatMessage(
        id: 0,
        by: _snapshot.you ?? '',
        name: _profile.name ?? '',
        text: clean,
        at: DateTime.now().millisecondsSinceEpoch,
        cid: cid,
        delivery: ChatDelivery.sending,
        reply: reply,
      ),
    ];
    var sent = false;
    try {
      sent = await _backend.sendChat(clean, cid, reply: reply?.id, quote: reply);
    } on Object {
      // Shown as not sent, with the way to try again
    }
    if (!sent) return _chatFailed(cid);
    // Already confirmed while the call came back
    final waiting = chat.value.any(
      (m) => m.cid == cid && m.delivery == ChatDelivery.sending,
    );
    if (!waiting) return;
    _chatDeadlines[cid] = Timer(chatDeliveryTimeout, () => _chatFailed(cid));
  }

  /// Tries [message], which did not reach the room, once more.
  Future<void> resendChat(ChatMessage message) {
    chat.value = [
      for (final m in chat.value)
        if (m.cid != message.cid) m,
    ];
    return sendChat(message.text, reply: message.reply);
  }

  /// Gives [message] this device's [reaction], or ([reaction] null) takes the one it gave away. It shows at once.
  void reactToMessage(ChatMessage message, Reaction? reaction) {
    final you = _snapshot.you;
    if (!hasChat || you == null || message.delivery != ChatDelivery.sent) return;
    chat.value = [
      for (final m in chat.value)
        if (m.delivery == ChatDelivery.sent && m.id == message.id)
          m.withReaction(you, reaction)
        else
          m,
    ];
    _run(() => _backend.reactChat(message.id, reaction));
  }

  /// How far the others have got with [message], a message of this device's own: nothing for one that is not.
  ChatProgress progressOf(ChatMessage message) {
    if (message.delivery == ChatDelivery.failed) return const ChatProgress.failed();
    if (message.delivery == ChatDelivery.sending) return const ChatProgress.sending();
    final you = _snapshot.you;
    final seenBy = <String>[];
    var delivered = false;
    for (final MapEntry(key: id, value: receipt) in receipts.value.entries) {
      if (id == you) continue;
      if (receipt.read >= message.id) seenBy.add(id);
      if (receipt.delivered >= message.id) delivered = true;
    }
    if (seenBy.isNotEmpty) {
      return ChatProgress.seen([for (final id in seenBy) chatterName(id)]);
    }
    return delivered ? const ChatProgress.delivered() : const ChatProgress.sent();
  }

  /// A member's name: as the room lists them, or as they signed what they wrote if they have left.
  String chatterName(String id) {
    final listed = _snapshot.nameOf(id);
    if (listed.isNotEmpty) return listed;
    for (final m in chat.value.reversed) {
      if (m.by == id && m.name.isNotEmpty) return m.name;
    }
    return S.someone;
  }

  /// For each message, the members whose last look at the chat ended there, so their pictures can mark the place.
  Map<int, List<String>> readMarkers(List<ChatMessage> messages) {
    final markers = <int, List<String>>{};
    final sent = [for (final m in messages) if (m.delivery == ChatDelivery.sent) m];
    for (final MapEntry(key: id, value: receipt) in receipts.value.entries) {
      if (id == _snapshot.you || receipt.read <= 0) continue;
      final at = sent.lastIndexWhere((m) => m.id <= receipt.read);
      // Their own message is where they have always got to; a mark there says nothing
      if (at < 0 || sent[at].by == id) continue;
      markers.putIfAbsent(sent[at].id, () => []).add(id);
    }
    return markers;
  }

  void _chatFailed(String cid) {
    _chatDeadlines.remove(cid)?.cancel();
    chat.value = [
      for (final m in chat.value)
        m.cid == cid && m.delivery == ChatDelivery.sending
            ? m.withDelivery(ChatDelivery.failed)
            : m,
    ];
  }

  /// Sends the room [reaction]. It shows here at once; quick taps go to the room together.
  void react(Reaction reaction) {
    if (!hasChat) return;
    _reactions.add(RoomReaction(name: S.you, reaction: reaction, mine: true));
    _reactionTaps[reaction] = (_reactionTaps[reaction] ?? 0) + 1;
    _reactionFlush ??= Timer(reactionGathering, _sendReactions);
  }

  void _sendReactions() {
    _reactionFlush = null;
    final taps = Map.of(_reactionTaps);
    _reactionTaps.clear();
    for (final MapEntry(key: reaction, value: count) in taps.entries) {
      final n = count < maxReactionCount ? count : maxReactionCount;
      _run(() => _backend.react(reaction, n));
    }
  }

  /// Lets the native side know which language is shown, for the texts it writes itself.
  Future<void> setLanguage(String code) => _backend.setLanguage(code);

  String? _describe(ServerError error) {
    // This device's own player: the message is the song's title, and from the iPhone a second line says what went wrong
    final lines = error.message.split('\n');
    final song = lines.first.isEmpty ? S.thisSong : lines.first;
    final cause = lines.skip(1).join(' ').trim();
    final own = switch (error.code) {
      'load_slow' => S.loadSlow(song),
      'load_offline' => S.loadOffline(song),
      'load_skipped' => S.loadSkipped(song),
      'load_unplayable' => S.loadUnplayable(song),
      'load_failed' => S.loadFailed(song),
      _ => null,
    };
    if (own != null) return cause.isEmpty ? own : '$own\n$cause';
    if (error.code == 'unplayable') {
      // The message reads "Nobody could load: <title>", and from the iPhone a second line says what went wrong
      final lines = error.message.split('\n');
      final title = lines.first.split(': ').skip(1).join(': ');
      final text = S.unplayable(title.isEmpty ? S.thisSong : title);
      final cause = lines.skip(1).join(' ').trim();
      return cause.isEmpty ? text : '$text\n$cause';
    }
    return S.serverError(error.code) ?? error.message;
  }

  // ------------------------------------------------------------------ derived state

  /// Position of the current song now, in ms.
  int positionMs() {
    final target = _seekTarget;
    if (target != null) return target;
    final p = player.value;
    if (!p.playing) return p.positionMs;
    final advanced =
        p.positionMs + (_sinceSample.elapsedMilliseconds * p.speed).round();
    final limit = p.durationMs > 0 ? p.durationMs : advanced;
    return advanced < limit ? advanced : limit;
  }

  /// Total length of the current song: from the player once known, else from the queue entry.
  int durationMs() {
    final fromPlayer = player.value.durationMs;
    return fromPlayer > 0 ? fromPlayer : (_snapshot.current?.durMs ?? 0);
  }

  /// Sound is coming or is already playing (used for the play/pause glyph). Outside a room, and while
  /// listening alone, this is about this device's own player, not the room; in a room it is the room's, unless
  /// this device was paused by itself ([PlayerPosition.heldBack]) and the room plays on without it.
  bool get isPlaying => _snapshot.ownPlayback
      ? (_soloPlaying ??
            (player.value.playing ||
                player.value.buffering ||
                _snapshot.loading))
      : _snapshot.wantsPlaying && !player.value.heldBack;

  /// The room started something but nothing is audible yet: everyone is still loading. On this device's own player,
  /// the song is being found or buffered.
  bool get isStarting => _snapshot.ownPlayback
      ? isPlaying && (player.value.buffering || _snapshot.loading)
      : _snapshot.phase == 'preparing' || (isPlaying && player.value.buffering);

  // ------------------------------------------------------------------ room

  /// The songs a room made now would start with: the one playing outside a room and those coming after it, as many as
  /// a room holds and none from the phone's own files (the others do not have them). Empty unless a song plays here.
  List<Track> get songsForNewRoom {
    final current = _snapshot.current;
    if (_snapshot.inRoom || !isPlaying || current == null || current.isLocal) {
      return const [];
    }
    return [
      current,
      ..._snapshot.upNext.where((e) => !e.isLocal),
    ].take(queueMax(inRoom: true)).toList();
  }

  /// Returns null on success, else a message for the user. With [withSongs] the room starts with [songsForNewRoom],
  /// the first one from where it is now.
  Future<String?> createRoom(String name, {bool withSongs = false}) async {
    final songs = withSongs ? songsForNewRoom : const <Track>[];
    final atMs = positionMs();
    try {
      await _backend.createRoom(name.trim());
    } on Object catch (e) {
      return _roomFailure(S.createFailed, e);
    }
    if (songs.isNotEmpty) unawaited(_startRoomWith(songs, atMs));
    return null;
  }

  /// Puts [songs] on a room just made and plays the first from [atMs]: an idle room plays the first song it is given,
  /// and a seek while it is still preparing is where it starts. Nothing more is tried if the room does not get there.
  Future<void> _startRoomWith(List<Track> songs, int atMs) async {
    if (!await _reach((s) => s.inRoom && s.you != null)) return;
    await addMany(songs);
    if (atMs < 1000) return;
    if (!await _reach((s) => s.current?.videoId == songs.first.videoId)) {
      return;
    }
    await _run(() => _backend.seek(atMs));
  }

  /// Waits until the state passes [test], for some seconds at most; false when it did not.
  Future<bool> _reach(bool Function(RoomSnapshot snapshot) test) async {
    if (test(_snapshot)) return true;
    final reached = Completer<bool>();
    void check() {
      if (!reached.isCompleted && test(_snapshot)) reached.complete(true);
    }

    addListener(check);
    try {
      return await reached.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
    } finally {
      removeListener(check);
    }
  }

  Future<String?> join(String code, String name) async {
    try {
      await _backend.join(code.trim().toUpperCase(), name.trim());
      return null;
    } on Object catch (e) {
      return _roomFailure(S.joinFailed, e);
    }
  }

  /// What the person is told when a room could not be made or joined: words they can act on, never the exception
  /// itself, which goes to the log instead.
  String _roomFailure(String failed, Object error) {
    if (error is BackendException) {
      if (error.code == 'not_configured') return S.serverNotSet;
      final known = S.serverError(error.code);
      if (known != null) return known;
    }
    _backend.note('room failed: $error').ignore();
    return '$failed. ${S.checkConnection}';
  }

  /// Where the room server is and its key; what is left out stays as it was.
  Future<void> configure({String? server, String? key}) async {
    await _backend.configure(server: server, key: key);
    _profile = await _backend.profile();
    await _readGroupKey();
    notifyListeners();
  }

  /// Asks the server whether it answers, takes the key and is new enough for this app.
  Future<ServerCheck> checkServer() async {
    try {
      return await _backend.checkServer();
    } on Object {
      return const ServerCheck();
    }
  }

  /// The link that sets up another phone like this one; null when this one has no server.
  Future<String?> setupLink() => _backend.setupLink();

  Future<void> leave() => _run(_backend.leave);

  /// Address that opens the app on this room from a chat message, or the app's own link when the
  /// server's address is not known. For a room whose chat is end-to-end encrypted it carries the secret that opens the
  /// chat, after a `#` so that the server never sees it.
  /// It also carries the group key, so that somebody who never used Sapoche gets in with this one link in a browser.
  String inviteLink(String code) {
    final server = _profile.server;
    final key = _groupKey ?? '';
    final after = [
      if (_secretOf == code && _secret != null) 'k=$_secret',
      // Only on a link the browser can open: the app's own link goes to an app that has the key already
      if (server.isNotEmpty && key.isNotEmpty) 'key=${Uri.encodeComponent(key)}',
    ];
    final base = server.isEmpty ? 'sapoche://join/$code' : '$server/join/$code';
    return after.isEmpty ? base : '$base#${after.join('&')}';
  }

  /// The key the server asks for, read from the link that sets up another device ([setupLink]), which holds it.
  String? _groupKey;

  Future<void> _readGroupKey() async {
    try {
      final link = await _backend.setupLink();
      if (link == null) {
        _groupKey = null;
        return;
      }
      // A phone's link is a setup link; the web's opens the web app with the key after a #
      final fragment = Uri.tryParse(link)?.fragment ?? '';
      _groupKey =
          SetupLink.parse(link)?.key ??
          (fragment.contains('=') ? Uri.splitQueryString(fragment)['key'] : null);
    } on Object {
      // Invitations then carry only the code, as they always did
    }
  }

  /// The secret of the room this device is in, once it has it and the room's chat is end-to-end encrypted.
  String? _secret;
  String? _secretOf;

  void _syncSecret(RoomSnapshot snapshot) {
    final code = snapshot.room;
    if (code == null || !snapshot.encryptionKey) {
      if (_secret != null) {
        _secret = null;
        _secretOf = null;
      }
      return;
    }
    if (_secretOf == code && _secret != null) return;
    _secretOf = code;
    _backend
        .roomSecret()
        .then((secret) {
          if (_secretOf != code || secret == null) return;
          _secret = secret;
          notifyListeners();
        })
        .catchError((Object _) {});
  }

  /// Owner only: turns on end-to-end encryption of this room's chat for good. The chat so far is deleted, and the others
  /// need the new invitation link (see [inviteLink]) to read what comes. False when this device cannot.
  Future<bool> enableEncryption() async {
    try {
      return await _backend.enableEncryption();
    } on Object {
      return false;
    }
  }

  /// Takes the secret out of an invitation link the person pasted, and keeps it for its room. The room and whether the
  /// link had a secret in it; null when [text] is no invitation.
  Future<InviteSecret?> acceptInvite(String text) async {
    final found = InviteSecret.parse(text);
    final secret = found?.secret;
    if (found == null || secret == null) return found;
    final kept = await _backend.setRoomSecret(found.room, secret);
    return kept ? found : InviteSecret(room: found.room);
  }

  /// What the server says about a room, for the list of recent ones.
  Future<RoomInfo?> roomInfo(String code) => _backend.roomInfo(code);

  Future<void> setRoomName(String name) =>
      _run(() => _backend.setRoomName(name.trim()));

  /// Gives the room's chat the look [theme], with [background] behind it or, without, no picture. Every member sees it.
  Future<void> setTheme(String theme, {Uint8List? background}) => _run(
    () => _backend.setRoomTheme(
      theme,
      background: background == null ? null : base64Encode(background),
    ),
  );

  Future<void> setGuestControl(GuestControl mode) =>
      _run(() => _backend.setGuestControl(mode));

  Future<void> setRoomAutoplay(bool on) =>
      _run(() => _backend.setRoomAutoplay(on));

  /// Owner only: remove a member from the room.
  Future<void> kick(Member member) => _run(() => _backend.kick(member.id));

  /// Changes the name the others see; playback carries on.
  Future<void> rename(String name) async {
    await _run(() => _backend.rename(name.trim()));
    // Outside a room there is no state to carry the name back: read it where it is kept
    try {
      _profile = await _backend.profile();
      notifyListeners();
    } on Object {
      // The name shown stays as it was
    }
  }

  /// Sends the room code (and a link that opens the app on it) through the share sheet.
  Future<void> shareInvite() {
    final code = _snapshot.room;
    if (code == null) return Future.value();
    return _run(() => _backend.share(S.inviteText(code, inviteLink(code))));
  }

  // ------------------------------------------------------------------ transport

  Future<void> togglePlay() {
    final playing = isPlaying;
    if (_snapshot.ownPlayback) {
      _soloPlaying = !playing;
      notifyListeners();
    }
    return _run(playing ? _backend.pause : _backend.play);
  }

  /// Listen on this device alone ([on]) or follow the room again.
  Future<void> setSolo(bool on) => _run(() => _backend.setSolo(on));

  /// Opens the system's list of places to play to.
  Future<void> pickOutput() => _run(_backend.pickOutput);

  /// Sets the volume of the device; the slider follows at once and the device's own value comes back as an event.
  Future<void> setVolume(double level) {
    volume.value = level.clamp(0.0, 1.0);
    return _run(() => _backend.setVolume(volume.value));
  }

  /// Shows [picture] to the room as this device's own, or with null takes it away. A picture too big to send stays
  /// on this phone.
  Future<void> shareAvatar(Uint8List? picture) {
    final text = picture == null ? null : base64Encode(picture);
    return _run(
      () => _backend.setAvatar(
        text != null && text.length <= maxAvatarChars ? text : null,
      ),
    );
  }

  /// The longest base64 text of a picture the room accepts.
  static const maxAvatarChars = 24000;

  /// Carry on playing by myself after the room paused.
  Future<void> keepPlaying() => _run(_backend.keepPlaying);
  Future<void> next() => _run(_backend.next);
  Future<void> prev() => _run(_backend.prev);
  Future<void> jump(QueueEntry entry) => _run(() => _backend.jump(entry.id));

  Future<void> seek(int positionMs) {
    _seekTarget = positionMs;
    _seekTimer?.cancel();
    _seekTimer = Timer(
      const Duration(milliseconds: 1500),
      () => _seekTarget = null,
    );
    return _run(() => _backend.seek(positionMs));
  }

  // ------------------------------------------------------------------ queue

  /// Songs that are waiting in the queue already are not added again.
  Future<void> add(Track track, {bool playNext = false}) async {
    if (_snapshot.isQueued(track)) return;
    // The others in a room do not have the file
    if (_snapshot.inRoom && track.isLocal) {
      _messages.add(S.localNoRoom);
      return;
    }
    await _run(() => _backend.add(track, playNext: playNext));
  }

  /// Plays [other], another release of the song, in place of [entry].
  Future<void> swapVersion(QueueEntry entry, Track other) =>
      _run(() => _backend.swap(entry.id, other));

  Future<void> remove(QueueEntry entry) =>
      _run(() => _backend.remove(entry.id));

  /// Takes [track] off the queue again just after it was put there: the last place it waits, never the song playing.
  Future<void> undoAdd(Track track) async {
    final entry = _snapshot.queue
        .skip(_snapshot.index + 1)
        .where((e) => e.videoId == track.videoId)
        .lastOrNull;
    if (entry != null) await remove(entry);
  }
  Future<void> move(QueueEntry entry, int toIndex) =>
      _run(() => _backend.move(entry.id, toIndex));
  Future<void> clearQueue() => _run(_backend.clear);
  Future<void> shuffle() => _run(_backend.shuffle);

  Future<void> setShuffle(bool on) => _run(() => _backend.setShuffle(on));

  /// Puts [tracks] on the queue and says how many went on: those that were there already, those from files in a room
  /// and those past what the queue holds are left out.
  Future<int> addMany(List<Track> tracks, {bool playNext = false}) async {
    var fresh = _snapshot.fresh(tracks);
    final inRoom = _snapshot.inRoom;
    // The others in a room do not have the files: only what is on YouTube goes in, and the rest is said
    if (inRoom) {
      final sendable = [
        for (final t in fresh)
          if (!t.isLocal) t,
      ];
      if (sendable.length != fresh.length) {
        _messages.add(
          sendable.isEmpty
              ? S.localNoRoom
              : S.localLeftOut(fresh.length - sendable.length),
        );
      }
      fresh = sendable;
    }
    // A queue that is full says so itself, asked for one song
    final space = max(1, queueMax(inRoom: inRoom) - _snapshot.queue.length);
    if (fresh.length > space) fresh = fresh.sublist(0, space);
    if (fresh.isEmpty) return 0;
    if (!inRoom) {
      await _run(() => _backend.addMany(fresh, playNext: playNext));
      return fresh.length;
    }
    // The server takes so many at a time. Each lot goes right after the song playing when they play next, so the
    // last lot is sent first
    final lots = [
      for (var i = 0; i < fresh.length; i += _serverAddMany)
        fresh.sublist(i, min(i + _serverAddMany, fresh.length)),
    ];
    for (final lot in playNext ? lots.reversed : lots) {
      await _run(() => _backend.addMany(lot, playNext: playNext));
    }
    return fresh.length;
  }

  /// Outside a room: replaces the queue with [tracks] and starts them. In a room the queue belongs
  /// to everybody, so they are only added to it. Says how many are on the queue now.
  Future<int> playTracks(List<Track> tracks) {
    if (_snapshot.inRoom) return addMany(tracks);
    final songs = uniqueSongs(tracks);
    final kept = songs.length > queueMax(inRoom: false)
        ? songs.sublist(0, queueMax(inRoom: false))
        : songs;
    // Taps in quick succession are taken in turn, so that each empties the queue before its songs go in and the
    // last one is what plays. The songs are not checked against the queue here: until the native side reports
    // the emptied queue, the snapshot still holds the old one, and every song in it would be left out
    _replacing = _replacing.then((_) async {
      await _run(_backend.clear);
      await _run(() => _backend.addMany(kept));
    });
    return _replacing.then((_) => kept.length);
  }

  /// Outside a room: plays [track] in place of the queue and lets songs like it follow, as YouTube Music does
  /// when a song is tapped.
  Future<void> playSong(Track track) async {
    await playTracks([track]);
    // A song from a file has no radio
    if (track.isLocal) return;
    await _run(() => _backend.fillRadio(track.videoId));
  }

  /// Stops the music in [minutes]; with [SleepMode.song] at the end of this song, with [SleepMode.off] never.
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) =>
      _run(() => _backend.setSleep(mode, minutes: minutes));

  Future<void> cycleRepeat() =>
      _run(() => _backend.setRepeat(_snapshot.repeat.next));

  // ------------------------------------------------------------------ search and settings

  /// Looks up the streams of the first songs of [tracks], a list on the screen, so that a touch on one of them plays at
  /// once instead of after the few seconds a lookup takes. The phone's own files need none.
  void warmUp(List<Track> tracks) {
    final ids = [
      for (final t in tracks)
        if (!t.isLocal) t.videoId,
    ].take(_warmCount).toList();
    if (ids.isNotEmpty) _backend.warm(ids).ignore();
  }


  Future<List<Track>> search(
    String query, {
    bool songsOnly = false,
    int? limit,
  }) => _backend.search(query, songsOnly: songsOnly, limit: limit);
  Future<LinkResult?> lookup(String text) => _backend.lookup(text);

  /// Whether the music carries on with similar songs when the queue runs out.
  bool get autoplay => _profile.autoplay;

  Future<void> setAutoplay(bool on) {
    _profile = _profile.withAutoplay(on);
    notifyListeners();
    return _run(() => _backend.setAutoplay(on));
  }

  /// How much sound a song that is not kept yet is fetched in.
  AudioQuality get audioQuality => _profile.audioQuality;

  Future<void> setAudioQuality(AudioQuality quality) {
    _profile = _profile.withAudioQuality(quality);
    notifyListeners();
    return _run(() => _backend.setAudioQuality(quality));
  }

  /// What YouTube would complete a half-typed search to.
  Future<List<String>> suggest(String query) async {
    try {
      return await _backend.suggest(query);
    } on Object {
      return const [];
    }
  }

  Future<void> setTrim(int ms) => _run(() => _backend.setTrim(ms));

  /// Play songs with their picture on this device, or sound only.
  Future<void> setVideoMode(bool on) => _run(() => _backend.setVideoMode(on));

  /// The picture views that are seen now. When the phone turns, the new layout's view comes before the old one's
  /// goes, so a view that leaves must not hide the picture another still shows: the player is told whether any is seen.
  final Set<Object> _videoViewsSeen = {};

  /// Whether [view], a picture view, is seen: on screen with the app in front.
  Future<void> setVideoSeen(Object view, bool seen) {
    if (seen) {
      _videoViewsSeen.add(view);
    } else {
      _videoViewsSeen.remove(view);
    }
    _updateWatching();
    return _run(() => _backend.setVideoVisible(_videoViewsSeen.isNotEmpty));
  }

  /// What the native side was last told by [_updateWatching].
  (bool, int, int)? _watching;

  /// The size of the last picture, kept while a new song has none yet so the small window keeps its shape.
  (int, int) _pictureSize = (16, 9);

  /// Tells the native side whether somebody watches the picture: it is on screen and the music plays. Then the screen
  /// stays on, and leaving the app moves the picture into a small window. A song that is buffering still counts as
  /// playing, or the screen could go dark at once in the middle of a video.
  void _updateWatching() {
    final p = player.value;
    if (p.videoWidth > 0 && p.videoHeight > 0) {
      _pictureSize = (p.videoWidth, p.videoHeight);
    }
    final on = _snapshot.video && _videoViewsSeen.isNotEmpty && isPlaying;
    final next = (on, _pictureSize.$1, _pictureSize.$2);
    if (next == _watching) return;
    _watching = next;
    _run(() => _backend.setVideoWatching(on, width: next.$2, height: next.$3));
  }

  /// Plays faster or slower than normal (1). Only outside a room: in one the speed keeps the phones in step.
  Future<void> setPlaybackSpeed(double speed) {
    if (_snapshot.inRoom) return Future.value();
    return _run(() => _backend.setPlaybackSpeed(speed));
  }

  /// Moves the picture into a small window over other apps.
  Future<void> enterPictureInPicture() => _run(_backend.enterPictureInPicture);

  /// The texture the picture is drawn into, or null when it cannot be made.
  Future<int?> videoSurface() async {
    try {
      return await _backend.videoSurface();
    } on Object {
      return null;
    }
  }

  Future<void> setVideoQuality(int height) =>
      _run(() => _backend.setVideoQuality(height));
  /// The diary of the native side, as Settings copies it; a key or the secret of a room in any link of it is hidden,
  /// whichever side wrote the line.
  Future<List<String>> log() async => [
    for (final line in await _backend.log())
      line.replaceAllMapped(_secretInLink, (m) => '${m[1]}…'),
  ];

  /// Turns the notices of the chat on or off. Called from a touch: the system's leave can only be asked for from one.
  Future<void> setNotifications(bool on) => _run(() async {
    _noticeInfo = await _backend.setNotifications(on);
    notifyListeners();
  });

  Future<void> setNotificationPreview(bool on) => _run(() async {
    await _backend.setNotificationPreview(on);
    await _refreshNotices();
    notifyListeners();
  });

  /// Keeps the room the person is in quiet for [length], or with null makes it loud again. A room cannot be kept quiet
  /// outside it, as no notice would come from it.
  Future<void> muteNotifications(Duration? length) => _run(() async {
    final code = _snapshot.room;
    if (code == null) return;
    await _backend.muteRoomNotifications(code, length == null ? null : DateTime.now().add(length).millisecondsSinceEpoch);
    await _refreshNotices();
    notifyListeners();
  });

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on BackendException catch (e) {
      _messages.add(e.code == 'no_room' ? S.notInRoom : e.message);
    } on Object catch (e) {
      _messages.add('$e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _seekTimer?.cancel();
    _messages.close();
    _notices.close();
    _reactions.close();
    volume.dispose();
    _reactionFlush?.cancel();
    for (final timer in _lateTimers) {
      timer.cancel();
    }
    for (final timer in _chatDeadlines.values) {
      timer.cancel();
    }
    chat.dispose();
    unreadChat.dispose();
    player.dispose();
    playState.dispose();
    invite.dispose();
    setup.dispose();
    pictureInPicture.dispose();
    chatRequests.dispose();
    super.dispose();
  }
}
