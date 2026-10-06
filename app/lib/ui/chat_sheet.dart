import 'dart:math';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
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
  const ChatButton({super.key, required this.controller, this.color});

  final RoomController controller;
  final Color? color;

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

class _ChatSheetState extends State<ChatSheet> {
  final _field = TextEditingController();

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // After this frame: what it changes is shown by buttons being built along with the sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.setChatOpen(true);
    });
  }

  @override
  void dispose() {
    _c.setChatOpen(false);
    _field.dispose();
    super.dispose();
  }

  void _send() {
    final text = _field.text;
    if (text.trim().isEmpty) return;
    _field.clear();
    _c.sendChat(text);
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
                    Expanded(child: Text(S.chat, style: theme.headlineSmall)),
                    Text(
                      S.listening(_c.snapshot.listeningCount),
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ReactionShower(
              controller: _c,
              child: ValueListenableBuilder(
                valueListenable: _c.chat,
                builder: (context, messages, _) => messages.isEmpty
                    ? const _EmptyChat()
                    : _Messages(controller: _c, messages: messages),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ReactionBar(controller: _c),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-field'),
                    controller: _field,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: RoomController.maxChatChars,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
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
                ValueListenableBuilder(
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
              ],
            ),
          ),
        ],
      ),
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

class _Messages extends StatelessWidget {
  const _Messages({required this.controller, required this.messages});

  final RoomController controller;
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final you = controller.snapshot.you;
    // Upside down, so the newest message sits at the bottom and the list opens there
    return ListView.builder(
      reverse: true,
      // Pulling the messages puts the keyboard away, as in the chats of the phone
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: messages.length,
      itemBuilder: (context, i) {
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
        return Column(
          children: [
            if (showTime) _TimeLine(at: at),
            _Bubble(
              controller: controller,
              message: message,
              mine: message.by == you || message.delivery != ChatDelivery.sent,
              startsGroup: startsGroup,
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
    final now = DateTime.now();
    final time = TimeOfDay.fromDateTime(at).format(context);
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final text = today
        ? time
        : '${MaterialLocalizations.of(context).formatShortDate(at)} $time';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
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
  });

  final RoomController controller;
  final ChatMessage message;
  final bool mine;
  final bool startsGroup;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final failed = message.delivery == ChatDelivery.failed;
    const avatarSize = 28.0;
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? p.primary : p.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        message.text,
        style: theme.bodyMedium?.copyWith(color: mine ? p.onPrimary : p.text),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: startsGroup ? 8 : 2),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
          Row(
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
                  onTap: failed ? () => controller.resendChat(message) : null,
                  child: Opacity(
                    opacity: message.delivery == ChatDelivery.sent ? 1 : 0.6,
                    child: bubble,
                  ),
                ),
              ),
            ],
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
            ),
        ],
      ),
    );
  }
}
