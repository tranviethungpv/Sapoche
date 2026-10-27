import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'rooms_sheet.dart' show pasteInviteSecret;
import 'scope.dart';
import 'widgets/avatars.dart';
import 'widgets/reactions.dart';

/// The room's chat, over whatever is shown: messages, the reactions, and a field to write in.
void showChatSheet(BuildContext context) {
  final controller = AppScope.roomOf(context);
  showModalBottomSheet<void>(
    useRootNavigator: true,
    // Below the status bar, the notch and the island, keyboard or not
    useSafeArea: true,
    context: context,
    isScrollControlled: true,
    builder: (_) => ChatSheet(controller: controller),
  );
}

/// The way into the chat, with how many messages came since it was last open. Nothing where the room has no chat.
class ChatButton extends StatelessWidget {
  const ChatButton({
    super.key,
    required this.controller,
    this.color,
    this.size,
  });

  final RoomController controller;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.unreadChat]),
      builder: (context, _) {
        if (!controller.hasChat) return const SizedBox.shrink();
        final unread = controller.unreadChat.value;
        return IconButton(
          onPressed: () => showChatSheet(context),
          tooltip: unread == 0
              ? S.chat
              : '${S.chat} · ${S.unreadMessages(unread)}',
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: size,
              color: color ?? context.palette.primary,
            ),
          ),
        );
      },
    );
  }
}

class ChatSheet extends StatefulWidget {
  const ChatSheet({super.key, required this.controller});

  final RoomController controller;

  @override
  State<ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<ChatSheet> with WidgetsBindingObserver {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  /// The message being answered, shown above the field.
  ChatQuote? _replyTo;

  /// The message whose time is shown (a touch on a message shows it, another touch hides it).
  Object? _timeShownOf;

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After this frame: what it changes is shown by buttons being built along with the sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.setChatOpen(true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The chat is looked at only while the app is: the others see a message as seen when it was
    _c.setChatOpen(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.setChatOpen(false);
    _field.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _field.text;
    if (text.trim().isEmpty) return;
    final reply = _replyTo;
    _field.clear();
    setState(() => _replyTo = null);
    _c.sendChat(text, reply: reply);
    // The keyboard stays up for the next one, as it does in the chats of the phone
    _focus.requestFocus();
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _replyToMessage(ChatMessage message) {
    if (message.delivery != ChatDelivery.sent) return;
    HapticFeedback.selectionClick();
    setState(() => _replyTo = ChatQuote(
      id: message.id,
      by: message.by,
      name: message.name,
      text: _excerpt(message.text),
    ));
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) {
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        return Padding(
          // Above the keyboard while it is up
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(
            // Most of the screen, and with the keyboard up all that is left above it
            height: min(box.maxHeight * 0.85, box.maxHeight - keyboard),
            child: _sheet(context, p, theme),
          ),
        );
      },
    );
  }

  Widget _sheet(BuildContext context, Palette p, TextTheme theme) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          // Pulling the sheet down by its head puts the keyboard away with it
          Listener(
            onPointerMove: (move) {
              if (move.delta.dy > 2) {
                FocusManager.instance.primaryFocus?.unfocus();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: ListenableBuilder(
                listenable: _c,
                builder: (context, _) => Row(
                  children: [
                    if (_c.snapshot.encrypted) ...[
                      Tooltip(
                        message: S.encryptionTitle,
                        child: Icon(
                          Icons.lock_outline_rounded,
                          key: const ValueKey('chat-encrypted'),
                          size: 20,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(child: Text(S.chat, style: theme.headlineSmall)),
                    Text(
                      S.listening(_c.snapshot.listeningCount),
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                    if (_c.notificationInfo.enabled) _MuteButton(controller: _c),
                  ],
                ),
              ),
            ),
          ),
          _NoticeOffer(controller: _c),
          Expanded(
            // Part of the field as far as a touch goes: pressing a message to drag it sideways or hold it must not put
            // the keyboard away; only a plain touch on the space between the messages does
            child: TextFieldTapRegion(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: ReactionShower(
                  controller: _c,
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      _c,
                      _c.chat,
                      _c.receipts,
                      _c.chatHasOlder,
                    ]),
                    builder: (context, _) =>
                        _c.snapshot.encrypted && !_c.snapshot.encryptionKey
                        ? _NeedsKey(controller: _c)
                        : _c.chat.value.isEmpty
                        ? const _EmptyChat()
                        : _Messages(
                            controller: _c,
                            messages: _c.chat.value,
                            hasOlder: _c.chatHasOlder.value,
                            scroll: _scroll,
                            timeShownOf: _timeShownOf,
                            onShowTime: (key) => setState(
                              () => _timeShownOf =
                                  _timeShownOf == key ? null : key,
                            ),
                            onReply: _replyToMessage,
                          ),
                  ),
                ),
              ),
            ),
          ),
          // The same: reacting while writing leaves the keyboard where it is
          TextFieldTapRegion(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ReactionBar(controller: _c),
            ),
          ),
          if (_replyTo case final reply?)
            TextFieldTapRegion(
              child: _ReplyBanner(
                quote: reply,
                mine: reply.by == _c.snapshot.you,
                onCancel: () => setState(() => _replyTo = null),
              ),
            ),
          // Without the key of a sealed chat there is nothing to write, and the others could not read it
          _UnlessLocked(
            controller: _c,
            child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-field'),
                    controller: _field,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: RoomController.maxChatChars,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    // Handled here, so that the keyboard's Send key does not put the keyboard away as well
                    onEditingComplete: _send,
                    // A touch anywhere else puts the keyboard away: its return key makes a new line
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    // The count shows only near the end, where it matters
                    buildCounter:
                        (
                          context, {
                          required currentLength,
                          required isFocused,
                          maxLength,
                        }) => currentLength > RoomController.maxChatChars - 50
                        ? Text('$currentLength/$maxLength')
                        : null,
                    decoration: InputDecoration(
                      hintText: S.chatHint,
                      isDense: true,
                      filled: true,
                      fillColor: p.primary.withValues(alpha: 0.08),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                // Part of the field as far as a touch outside it goes: sending must not put the keyboard away
                TextFieldTapRegion(
                  child: ValueListenableBuilder(
                    valueListenable: _field,
                    builder: (context, value, _) => IconButton(
                      onPressed: value.text.trim().isEmpty ? null : _send,
                      tooltip: S.chatSend,
                      icon: Icon(
                        Icons.send_rounded,
                        color: value.text.trim().isEmpty
                            ? p.textTertiary
                            : p.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

/// Shows [child] unless the chat is sealed and this device has not the key of the room.
class _UnlessLocked extends StatelessWidget {
  const _UnlessLocked({required this.controller, required this.child});

  final RoomController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) =>
        controller.snapshot.encrypted && !controller.snapshot.encryptionKey
        ? const SizedBox.shrink()
        : child,
  );
}

/// In a chat that is end-to-end encrypted, on a device that has not the key of the room: how to get it.
class _NeedsKey extends StatelessWidget {
  const _NeedsKey({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Center(
      key: const ValueKey('chat-needs-key'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, size: 40, color: p.textTertiary),
            const SizedBox(height: 12),
            Text(
              S.encryptionNeedsKey,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => pasteInviteSecret(context, controller),
              child: Text(S.encryptionPaste),
            ),
          ],
        ),
      ),
    );
  }
}

/// The start of a message, as a reply shows it.
String _excerpt(String text) {
  final chars = text.characters;
  return chars.length > 100 ? '${chars.take(100).toString().trimRight()}…' : text;
}

/// Above the field: who and what the message being written answers, and the way to drop it.
class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.quote,
    required this.mine,
    required this.onCancel,
  });

  final ChatQuote quote;
  final bool mine;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('chat-reply-banner'),
      margin: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: p.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mine ? S.chatReplyingToYourself : S.chatReplyingTo(quote.name),
                  style: theme.labelMedium?.copyWith(
                    color: p.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  quote.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.bodySmall?.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: S.chatCancelReply,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 18, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

enum _Mute { hour, eightHours, tomorrow, always, off }

/// Keeps the notices of this room quiet for a while, or turns them back on.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.controller});

  final RoomController controller;

  /// The notices of the night are over by this hour.
  static const _morning = 8;

  Duration _length(_Mute choice) {
    final now = DateTime.now();
    return switch (choice) {
      _Mute.hour => const Duration(hours: 1),
      _Mute.eightHours => const Duration(hours: 8),
      _Mute.tomorrow => DateTime(now.year, now.month, now.day + (now.hour < _morning ? 0 : 1), _morning).difference(now),
      _ => const Duration(days: 3650),
    };
  }

  @override
  Widget build(BuildContext context) {
    final until = controller.roomMutedUntil;
    return PopupMenuButton<_Mute>(
      key: const ValueKey('chat-mute'),
      tooltip: S.noticesMute,
      icon: Icon(until == null ? Icons.notifications_none_rounded : Icons.notifications_off_outlined),
      onSelected: (choice) => controller.muteNotifications(choice == _Mute.off ? null : _length(choice)),
      itemBuilder: (context) => [
        if (until != null) PopupMenuItem(value: _Mute.off, child: Text(S.noticesUnmute)) else ...[
          PopupMenuItem(value: _Mute.hour, child: Text(S.noticesMute1h)),
          PopupMenuItem(value: _Mute.eightHours, child: Text(S.noticesMute8h)),
          PopupMenuItem(value: _Mute.tomorrow, child: Text(S.noticesMuteTomorrow)),
          PopupMenuItem(value: _Mute.always, child: Text(S.noticesMuteAlways)),
        ],
      ],
    );
  }
}

/// Offers the notices of the chat to a person who has not turned them on, at the place where a message matters: here.
/// Once the person says "not now" the offer waits a week.
class _NoticeOffer extends StatefulWidget {
  const _NoticeOffer({required this.controller});

  final RoomController controller;

  @override
  State<_NoticeOffer> createState() => _NoticeOfferState();
}

class _NoticeOfferState extends State<_NoticeOffer> {
  static const _wait = Duration(days: 7);
  var _hidden = false;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final info = widget.controller.notificationInfo;
        final asked = settings.noticeOfferedAt;
        final due = asked == null || DateTime.now().difference(asked) > _wait;
        if (_hidden || !due || !info.supported || info.enabled || info.needsInstall || info.permission == NoticePermission.denied) {
          return const SizedBox.shrink();
        }
        final p = context.palette;
        return Container(
          key: const ValueKey('notice-offer'),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(color: p.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              Expanded(child: Text(S.noticesOffer, style: Theme.of(context).textTheme.bodyMedium)),
              TextButton(
                onPressed: () {
                  settings.noticeOfferedAt = DateTime.now();
                  setState(() => _hidden = true);
                },
                child: Text(S.noticesNotNow),
              ),
              FilledButton(
                onPressed: () {
                  setState(() => _hidden = true);
                  widget.controller.setNotifications(true);
                },
                child: Text(S.noticesTurnOn),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 40, color: p.primary),
            const SizedBox(height: 12),
            Text(S.chatEmpty, style: theme.titleMedium),
            const SizedBox(height: 4),
            Text(
              S.chatEmptyBody,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Messages of one person this close together share one name and one picture.
const _groupGap = Duration(minutes: 3);

/// A gap this long between two messages puts the time between them.
const _timeGap = Duration(minutes: 15);

/// The time of day, with the date when it was not today.
String _whenText(BuildContext context, DateTime at) {
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(at).format(context);
  final today =
      at.year == now.year && at.month == now.month && at.day == now.day;
  return today
      ? time
      : '${MaterialLocalizations.of(context).formatShortDate(at)} $time';
}

class _Messages extends StatelessWidget {
  const _Messages({
    required this.controller,
    required this.messages,
    required this.hasOlder,
    required this.scroll,
    required this.timeShownOf,
    required this.onShowTime,
    required this.onReply,
  });

  final RoomController controller;
  final List<ChatMessage> messages;

  /// The room keeps messages from before the first one: a row at the top asks for them as it comes into view.
  final bool hasOlder;
  final ScrollController scroll;
  final Object? timeShownOf;
  final ValueChanged<Object> onShowTime;
  final ValueChanged<ChatMessage> onReply;

  @override
  Widget build(BuildContext context) {
    final you = controller.snapshot.you;
    bool isMine(ChatMessage m) =>
        m.by == you || m.delivery != ChatDelivery.sent;
    final lastMine = messages.lastIndexWhere(isMine);
    final markers = controller.readMarkers(messages);
    // Upside down, so the newest message sits at the bottom and the list opens there
    return ListView.builder(
      reverse: true,
      controller: scroll,
      // Pulling the messages puts the keyboard away, as in the chats of the phone
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: messages.length + (hasOlder ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == messages.length) {
          // The top of what is shown: reaching it asks for the page before
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => controller.loadOlderChat(),
          );
          return const Padding(
            key: ValueKey('chat-older'),
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final index = messages.length - 1 - i;
        final message = messages[index];
        final before = index > 0 ? messages[index - 1] : null;
        final at = DateTime.fromMillisecondsSinceEpoch(message.at);
        final showTime =
            before == null ||
            at.difference(DateTime.fromMillisecondsSinceEpoch(before.at)) >
                _timeGap;
        final startsGroup =
            showTime ||
            before.by != message.by ||
            at.difference(DateTime.fromMillisecondsSinceEpoch(before.at)) >
                _groupGap;
        final key = message.delivery == ChatDelivery.sent
            ? message.id
            : message.cid;
        return Column(
          children: [
            if (showTime) _TimeLine(at: at),
            _Bubble(
              controller: controller,
              message: message,
              mine: isMine(message),
              startsGroup: startsGroup,
              timeShown: key != null && key == timeShownOf,
              progress: index == lastMine
                  ? controller.progressOf(message)
                  : null,
              readers: markers[message.id] ?? const [],
              onToggleTime: key == null ? null : () => onShowTime(key),
              onReply: () => onReply(message),
            ),
          ],
        );
      },
    );
  }
}

class _TimeLine extends StatelessWidget {
  const _TimeLine({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        _whenText(context, at),
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: context.palette.textTertiary),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.controller,
    required this.message,
    required this.mine,
    required this.startsGroup,
    required this.timeShown,
    required this.progress,
    required this.readers,
    required this.onToggleTime,
    required this.onReply,
  });

  final RoomController controller;
  final ChatMessage message;
  final bool mine;
  final bool startsGroup;

  /// A touch on the message showed its time.
  final bool timeShown;

  /// How far the message has come, for this device's last one; null for the others.
  final ChatProgress? progress;

  /// The members whose last look at the chat ended at this message.
  final List<String> readers;
  final VoidCallback? onToggleTime;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final failed = message.delivery == ChatDelivery.failed;
    final sent = message.delivery == ChatDelivery.sent;
    const avatarSize = 28.0;
    final ink = mine ? p.onPrimary : p.text;
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? p.primary : p.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.reply case final quote?)
            _Quote(
              quote: quote,
              own: quote.by == controller.snapshot.you,
              onBubbleOfMine: mine,
            ),
          message.locked
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 14, color: ink),
                    const SizedBox(width: 6),
                    Text(
                      S.chatLocked,
                      style: theme.bodyMedium?.copyWith(
                        color: ink.withValues(alpha: 0.8),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                )
              : Text(message.text, style: theme.bodyMedium?.copyWith(color: ink)),
        ],
      ),
    );
    final reactions = message.reactions;
    final side = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(
      padding: EdgeInsets.only(top: startsGroup ? 8 : 2),
      child: Column(
        crossAxisAlignment: side,
        children: [
          if (startsGroup && !mine)
            Padding(
              padding: const EdgeInsets.only(
                left: avatarSize + 8 + 4,
                bottom: 2,
              ),
              child: Text(
                message.name.isEmpty ? S.someone : message.name,
                style: theme.labelSmall?.copyWith(color: p.textSecondary),
              ),
            ),
          _SwipeToReply(
            toLeft: mine,
            enabled: sent && !message.locked,
            onReply: onReply,
            child: Row(
              mainAxisAlignment: mine
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!mine) ...[
                  // The picture once, beside the first message of a run
                  startsGroup
                      ? Avatar(
                          name: message.name,
                          size: avatarSize,
                          image: controller.avatarOf(message.by),
                        )
                      : const SizedBox(width: avatarSize),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: GestureDetector(
                    key: ValueKey('chat-message-${message.cid ?? message.id}'),
                    onTap: failed
                        ? () => controller.resendChat(message)
                        : onToggleTime,
                    // Words that cannot be read can be neither answered nor copied
                    onLongPress: message.locked
                        ? null
                        : () => _showMessageMenu(
                            context,
                            controller,
                            message,
                            onReply,
                          ),
                    child: Opacity(opacity: sent ? 1 : 0.6, child: bubble),
                  ),
                ),
              ],
            ),
          ),
          if (reactions.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: 3,
                left: mine ? 0 : avatarSize + 8,
              ),
              child: _ReactionPill(
                reactions: reactions,
                you: controller.snapshot.you,
                onTap: () =>
                    _showMessageMenu(context, controller, message, onReply),
              ),
            ),
          if (timeShown)
            Padding(
              padding: EdgeInsets.only(
                top: 3,
                left: mine ? 0 : avatarSize + 8,
                right: 4,
              ),
              child: Text(
                _whenText(
                  context,
                  DateTime.fromMillisecondsSinceEpoch(message.at),
                ),
                key: const ValueKey('chat-message-time'),
                style: theme.labelSmall?.copyWith(color: p.textTertiary),
              ),
            ),
          if (failed)
            GestureDetector(
              onTap: () => controller.resendChat(message),
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Text(
                  S.chatNotSent,
                  style: theme.labelSmall?.copyWith(color: p.error),
                ),
              ),
            )
          else if (progress != null || readers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: _Receipt(
                controller: controller,
                progress: progress,
                readers: readers,
              ),
            ),
        ],
      ),
    );
  }
}

/// What a reply carries of the message it answers, above the words of the reply.
class _Quote extends StatelessWidget {
  const _Quote({
    required this.quote,
    required this.own,
    required this.onBubbleOfMine,
  });

  final ChatQuote quote;

  /// The message answered was this device's own.
  final bool own;

  /// The reply sits in a bubble in the colour of this device's messages.
  final bool onBubbleOfMine;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final ink = onBubbleOfMine ? p.onPrimary : p.text;
    return Container(
      key: const ValueKey('chat-quote'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: ink.withValues(alpha: 0.7), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            own ? S.you : (quote.name.isEmpty ? S.someone : quote.name),
            style: theme.labelSmall?.copyWith(
              color: ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            quote.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.bodySmall?.copyWith(color: ink.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }
}

/// The reactions to a message, as small badges: each emoji given, and how many gave one.
class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.reactions,
    required this.you,
    required this.onTap,
  });

  final Map<String, Reaction> reactions;
  final String? you;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final counts = <Reaction, int>{};
    for (final reaction in reactions.values) {
      counts.update(reaction, (n) => n + 1, ifAbsent: () => 1);
    }
    final kinds = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final mineGiven = reactions.containsKey(you);
    return GestureDetector(
      key: const ValueKey('chat-reactions'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: mineGiven ? p.primary.withValues(alpha: 0.16) : p.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mineGiven ? p.primary : p.textTertiary.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in kinds.take(3))
              Text(kind.key.emoji, style: const TextStyle(fontSize: 14)),
            if (reactions.length > 1) ...[
              const SizedBox(width: 3),
              Text(
                '${reactions.length}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: p.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Under a message: how far this device's last one has come, and the pictures of those whose reading of the chat ended
/// at it.
class _Receipt extends StatelessWidget {
  const _Receipt({
    required this.controller,
    required this.progress,
    required this.readers,
  });

  final RoomController controller;
  final ChatProgress? progress;
  final List<String> readers;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final you = controller.snapshot.you;
    final progress = this.progress;
    final others = controller.snapshot.members.where((m) => m.id != you).length;
    final text = switch (progress?.stage) {
      null => null,
      ChatStage.sending => S.chatSending,
      ChatStage.failed => null,
      ChatStage.sent => S.chatSent,
      ChatStage.delivered => S.chatDelivered,
      ChatStage.seen => S.chatSeenBy(progress!.seenBy, others),
    };
    return Row(
      key: const ValueKey('chat-receipt'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text != null)
          Text(text, style: theme.labelSmall?.copyWith(color: p.textTertiary)),
        for (final id in readers.take(4))
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Avatar(
              name: controller.chatterName(id),
              size: 14,
              image: controller.avatarOf(id),
            ),
          ),
        if (readers.length > 4)
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Text(
              '+${readers.length - 4}',
              style: theme.labelSmall?.copyWith(color: p.textTertiary),
            ),
          ),
      ],
    );
  }
}

/// Drag a message sideways to answer it: the way the chats of the phone do. [toLeft] for the messages on the right.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.toLeft,
    required this.enabled,
    required this.onReply,
    required this.child,
  });

  final bool toLeft;
  final bool enabled;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _reach = 56.0;
  static const _limit = 80.0;

  double _dx = 0;
  bool _dragging = false;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (move) {
        final next = (_dx + move.delta.dx * 0.8).clamp(
          widget.toLeft ? -_limit : 0.0,
          widget.toLeft ? 0.0 : _limit,
        );
        final armed = next.abs() >= _reach;
        if (armed && !_armed) HapticFeedback.selectionClick();
        setState(() {
          _dx = next;
          _armed = armed;
        });
      },
      onHorizontalDragEnd: (_) {
        if (_armed) widget.onReply();
        setState(() {
          _dx = 0;
          _armed = false;
          _dragging = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _armed = false;
        _dragging = false;
      }),
      child: Stack(
        alignment: widget.toLeft ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Opacity(
            opacity: (_dx.abs() / _reach).clamp(0.0, 1.0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.reply_rounded,
                size: 22,
                color: _armed ? p.primary : p.textTertiary,
              ),
            ),
          ),
          AnimatedContainer(
            duration: _dragging ? Duration.zero : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// What a long touch on a message offers: a reaction to it, an answer, a copy, and who reacted.
Future<void> _showMessageMenu(
  BuildContext context,
  RoomController controller,
  ChatMessage message,
  VoidCallback onReply,
) {
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    useSafeArea: true,
    context: context,
    isScrollControlled: true,
    builder: (_) => _MessageMenu(
      controller: controller,
      message: message,
      onReply: onReply,
    ),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.controller,
    required this.message,
    required this.onReply,
  });

  final RoomController controller;
  final ChatMessage message;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sent = message.delivery == ChatDelivery.sent;
    final you = controller.snapshot.you;
    // Read again from the room: it may have changed while the menu was open
    final current = controller.chat.value.firstWhere(
      (m) => m.delivery == ChatDelivery.sent && m.id == message.id,
      orElse: () => message,
    );
    final mineGiven = current.reactions[you];
    void give(Reaction reaction) {
      controller.reactToMessage(current, mineGiven == reaction ? null : reaction);
      Navigator.of(context).pop();
    }

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sent)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final reaction in Reaction.quick)
                      InkResponse(
                        key: ValueKey('message-react-${reaction.name}'),
                        radius: 24,
                        onTap: () => give(reaction),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: mineGiven == reaction
                                ? p.primary.withValues(alpha: 0.18)
                                : null,
                          ),
                          child: Text(
                            reaction.emoji,
                            style: const TextStyle(fontSize: 26),
                          ),
                        ),
                      ),
                    IconButton(
                      key: const ValueKey('message-react-more'),
                      tooltip: S.reactMore,
                      onPressed: () async {
                        final picked = await pickReaction(context);
                        if (picked == null || !context.mounted) return;
                        give(picked);
                      },
                      icon: Icon(
                        Icons.add_reaction_outlined,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            if (sent)
              ListTile(
                key: const ValueKey('message-reply'),
                leading: Icon(Icons.reply_rounded, color: p.primary),
                title: Text(S.chatReply),
                onTap: () {
                  Navigator.of(context).pop();
                  onReply();
                },
              ),
            ListTile(
              key: const ValueKey('message-copy'),
              leading: Icon(Icons.copy_rounded, color: p.primary),
              title: Text(S.chatCopy),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.text));
                Navigator.of(context).pop();
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(S.chatCopied)),
                );
              },
            ),
            if (current.reactions.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(S.chatReactions, style: theme.titleSmall),
              ),
              for (final entry in current.reactions.entries)
                ListTile(
                  dense: true,
                  leading: Avatar(
                    name: controller.chatterName(entry.key),
                    size: 28,
                    image: controller.avatarOf(entry.key),
                  ),
                  title: Text(
                    entry.key == you
                        ? S.you
                        : controller.chatterName(entry.key),
                  ),
                  trailing: Text(
                    entry.value.emoji,
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
