import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/recent_rooms.dart';
import '../data/room_controller.dart';
import '../data/setup_link.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'code_sheet.dart';
import 'members_sheet.dart';
import 'scope.dart';
import 'settings_page.dart' show openSettings;
import 'setup_dialog.dart';
import 'widgets/motion.dart';
import 'widgets/sheet_tile.dart';
import 'widgets/qr_code_view.dart';
import 'widgets/text_dialog.dart';

/// The way into and out of a room: start one, join one, or share and manage the one this device is in.
/// [invitedCode] is a code that arrived with an invitation link.
///
/// In a room it opens on the invitation (QR, code, share), and on the room's settings with [settings].
Future<void> showRoomSheet(
  BuildContext context, {
  String? invitedCode,
  bool settings = false,
}) => showModalBottomSheet<void>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  sheetAnimationStyle: Motion.sheet(context),
  builder: (_) => _RoomSheet(invitedCode: invitedCode, settings: settings),
);

class _RoomSheet extends StatelessWidget {
  const _RoomSheet({this.invitedCode, this.settings = false});

  final String? invitedCode;
  final bool settings;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return ListenableBuilder(
      listenable: model.room,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: model.room.snapshot.inRoom
              ? _InRoom(room: model.room, settings: settings)
              : _StartRoom(
                  room: model.room,
                  recents: model.recents,
                  invitedCode: invitedCode,
                ),
        ),
      ),
    );
  }
}

/// Not in a room: a name, and the ways to get into one.
class _StartRoom extends StatefulWidget {
  const _StartRoom({
    required this.room,
    required this.recents,
    this.invitedCode,
  });

  final RoomController room;
  final RecentRooms recents;
  final String? invitedCode;

  @override
  State<_StartRoom> createState() => _StartRoomState();
}

class _StartRoomState extends State<_StartRoom> {
  late final _name = TextEditingController(
    text: widget.room.profile.name ?? '',
  );
  bool _busy = false;
  String? _error;

  /// An invitation that is waiting for a name: it is remembered, so that the person does not have to follow the link again.
  String? _pendingCode;

  @override
  void initState() {
    super.initState();
    final invited = widget.invitedCode;
    // A link or QR code that opened the app: go to that room, with the name this device already has
    if (invited != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _joinInvited(invited),
      );
    }
  }

  Future<void> _joinInvited(String code) async {
    if (!_requireName()) {
      _pendingCode = code;
      return;
    }
    _pendingCode = null;
    await _join(code);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool _requireName() {
    if (_name.text.trim().isNotEmpty) return true;
    setState(() => _error = S.enterName);
    return false;
  }

  /// Runs [enter], which gives back an error message or null. When it worked the sheet closes, unless
  /// [stayOpen]: it then turns into the room's own panel by itself, which is where an invitation is shared.
  Future<void> _enter(
    Future<String?> Function() enter, {
    bool stayOpen = false,
  }) async {
    if (!_requireName()) return;
    // The room's state can arrive before this returns and replace the sheet's content, so hold on to the route
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await enter();
    if (error == null) {
      if (!stayOpen) navigator.pop();
    } else if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _create({bool withSongs = false}) => _enter(
    () => widget.room.createRoom(_name.text, withSongs: withSongs),
    stayOpen: true,
  );

  Future<void> _join(String code) =>
      _enter(() => widget.room.join(code, _name.text));

  Future<void> _joinTyped() async {
    if (!_requireName()) return;
    final code = await showCodeSheet(context, initialCode: _pendingCode);
    if (code != null && mounted) {
      _pendingCode = null;
      await _join(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    // Without a server and its key a room cannot be made: say so at once, with the ways to get them, instead of
    // asking for a name first and then refusing
    final profile = widget.room.profile;
    if (!profile.configured || !profile.hasKey) {
      return _NeedsSetup(room: widget.room);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(S.listenTogether, style: theme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          S.roomSheetIntro,
          style: theme.bodyMedium?.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            FocusScope.of(context).unfocus();
            // The name an invitation was waiting for: carry on into that room
            final waiting = _pendingCode;
            if (waiting != null && _name.text.trim().isNotEmpty) {
              _joinInvited(waiting);
            }
          },
          maxLength: 24,
          // Says who will see the name, also once one is typed; under the field, since a floating label sits on the
          // edge of a filled field with no border
          decoration: InputDecoration(
            hintText: S.yourName,
            helperText: S.nameInRoom,
            counterText: '',
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: theme.bodySmall?.copyWith(color: p.error)),
        ],
        const SizedBox(height: 14),
        // While a song plays, the room starts with it and what comes after it; an empty room is the other way
        if (widget.room.songsForNewRoom.isNotEmpty) ...[
          FilledButton(
            onPressed: _busy ? null : () => _create(withSongs: true),
            child: Text(S.createRoomWithSong),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _busy ? null : _create,
            child: Text(S.createEmptyRoom),
          ),
        ] else
          FilledButton(
            onPressed: _busy ? null : _create,
            child: Text(S.createRoom),
          ),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: _busy ? null : _joinTyped,
          child: Text(S.joinRoom),
        ),
        ListenableBuilder(
          listenable: widget.recents,
          builder: (context, _) {
            final rooms = widget.recents.rooms;
            if (rooms.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 22),
                Text(S.recentRooms, style: theme.titleMedium),
                const SizedBox(height: 4),
                for (final room in rooms)
                  _RecentTile(
                    key: ValueKey(room.code),
                    room: room,
                    controller: widget.room,
                    enabled: !_busy,
                    onOpen: () => _join(room.code),
                    onForget: () => widget.recents.forget(room.code),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// This device has no server or key yet: a phone that has them shows a code to point the camera at, and its link can be
/// pasted here; the address and key can also be typed in the settings.
class _NeedsSetup extends StatelessWidget {
  const _NeedsSetup({required this.room});

  final RoomController room;

  Future<void> _paste(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final link = SetupLink.parse(data?.text ?? '');
    if (!context.mounted) return;
    if (link == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.setupBad)));
      return;
    }
    await askToUseSetup(context, room, link);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('room-needs-setup'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(S.setupNeededTitle, style: theme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          S.setupNeededBody,
          style: theme.bodyMedium?.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const ValueKey('room-setup-paste'),
          onPressed: () => _paste(context),
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: Text(S.setupPaste),
        ),
        const SizedBox(height: 10),
        ElevatedButton(
          key: const ValueKey('room-setup-manual'),
          onPressed: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            openSettings(navigator.context);
          },
          child: Text(S.setupEnterByHand),
        ),
      ],
    );
  }
}

/// A room from before, with what the server says about it right now.
class _RecentTile extends StatefulWidget {
  const _RecentTile({
    super.key,
    required this.room,
    required this.controller,
    required this.enabled,
    required this.onOpen,
    required this.onForget,
  });

  final RecentRoom room;
  final RoomController controller;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onForget;

  @override
  State<_RecentTile> createState() => _RecentTileState();
}

class _RecentTileState extends State<_RecentTile> {
  late final Future<RoomInfo?> _info = widget.controller.roomInfo(
    widget.room.code,
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FutureBuilder<RoomInfo?>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final gone = info != null && !info.exists;
        final status = info == null
            ? null
            : gone
            ? S.recentGone
            : S.recentLive(info.members);
        final title = info?.name ?? widget.room.title;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: widget.enabled && !gone,
          onTap: widget.onOpen,
          leading: CircleAvatar(
            backgroundColor: p.primaryContainer,
            child: Icon(
              Icons.graphic_eq_rounded,
              color: gone ? p.textTertiary : p.onPrimaryContainer,
            ),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (title != widget.room.code) widget.room.code,
              ?status,
            ].join(' · '),
            style: TextStyle(color: gone ? p.textTertiary : p.textSecondary),
          ),
          trailing: IconButton(
            onPressed: widget.onForget,
            tooltip: S.forgetRoom,
            icon: Icon(Icons.close_rounded, color: p.textTertiary),
          ),
        );
      },
    );
  }
}

/// In a room: first the invitation, the thing most wanted right after a room is made, and behind a button the room's
/// settings, which the owner can change.
class _InRoom extends StatefulWidget {
  const _InRoom({required this.room, this.settings = false});

  final RoomController room;
  final bool settings;

  @override
  State<_InRoom> createState() => _InRoomState();
}

class _InRoomState extends State<_InRoom> {
  late bool _settings = widget.settings;

  RoomController get room => widget.room;

  @override
  Widget build(BuildContext context) =>
      _settings ? _settingsView(context) : _inviteView(context);

  Widget _inviteView(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final code = room.snapshot.room ?? '';
    final link = room.inviteLink(code);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(S.invite, style: theme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(
          S.scanToJoin,
          style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Center(child: QrCodeView(data: link)),
        const SizedBox(height: 10),
        Center(
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _copy(context, code, S.codeCopied),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                code,
                style: theme.headlineSmall?.copyWith(letterSpacing: 6),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: room.shareInvite,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: FittedBox(fit: BoxFit.scaleDown, child: Text(S.invite, maxLines: 1)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _copy(context, link, S.linkCopied),
                icon: const Icon(Icons.link_rounded, size: 18),
                // One line, smaller when the words are long (Vietnamese): a button that breaks its label looks broken
                label: FittedBox(fit: BoxFit.scaleDown, child: Text(S.copyLink, maxLines: 1)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => setState(() => _settings = true),
          child: Text(S.roomSettings),
        ),
      ],
    );
  }

  Widget _settingsView(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final snapshot = room.snapshot;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(S.roomSettings, style: theme.headlineSmall),
        const SizedBox(height: 8),
        // Every row has the same make: an icon, what it is, a line on what it does, and its control at the end
        SheetTile(
          icon: Icons.headphones_rounded,
          title: S.listenTogether,
          help: snapshot.solo ? S.listenTogetherOff : S.listenTogetherOn,
          value: !snapshot.solo,
          onChanged: (together) => room.setSolo(!together),
        ),
        if (snapshot.iOwn)
          SheetTile(
            icon: Icons.playlist_add_rounded,
            title: S.guestsAddOnly,
            help: S.guestsAddOnlyHelp,
            value: snapshot.guestControl == GuestControl.add,
            onChanged: (on) =>
                room.setGuestControl(on ? GuestControl.add : GuestControl.all),
          ),
        // A server older than protocol 20 cannot wait for anybody
        if (snapshot.iOwn && snapshot.roomWaitWeak != null)
          SheetTile(
            icon: Icons.network_check_rounded,
            title: S.waitWeak,
            help: S.waitWeakHelp,
            value: snapshot.roomWaitWeak == true,
            onChanged: room.setRoomWaitWeak,
          ),
        if (room.hasChat && (snapshot.encrypted || snapshot.iOwn))
          EncryptionCard(room: room),
        if (snapshot.canControl)
          SheetTile(
            icon: Icons.edit_outlined,
            title: S.roomName,
            help: snapshot.name ?? S.addRoomName,
            onTap: () => _rename(context),
            chevron: true,
          ),
        SheetTile(
          icon: Icons.people_outline_rounded,
          title: S.peopleInRoom,
          help: S.listening(snapshot.listeningCount),
          onTap: () => showMembersSheet(context),
          chevron: true,
        ),
        SheetTile(
          icon: Icons.logout_rounded,
          title: S.leaveRoom,
          destructive: true,
          onTap: () => _confirmLeave(context),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showTextDialog(
      context,
      title: S.roomName,
      hint: S.roomNameHint,
      initial: room.snapshot.name ?? '',
      maxLength: 32,
    );
    if (name != null) room.setRoomName(name);
  }

  void _copy(BuildContext context, String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.leaveRoom),
        content: Text(S.leaveQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              S.leave,
              style: TextStyle(color: context.palette.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    Navigator.pop(context);
    room.leave();
  }
}

/// Whether the room's chat is end-to-end encrypted: a row of the settings, with a sentence and "Learn more" for the whole
/// story. The owner can turn it on, for good; once it is on, a device that has not the key (it joined without the link)
/// is told how to get it.
class EncryptionCard extends StatelessWidget {
  const EncryptionCard({super.key, required this.room});

  final RoomController room;

  /// The button of a row of settings is no taller than the switches beside it.
  static final _small = FilledButton.styleFrom(
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 16),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final snapshot = room.snapshot;
    final on = snapshot.encrypted;
    final noKey = on && !snapshot.encryptionKey;
    return KeyedSubtree(
      key: const ValueKey('encryption-card'),
      child: SheetTile(
        icon: Icons.lock_outline_rounded,
        title: S.encryptionTitle,
        help: noKey ? S.encryptionNoKey : S.encryptionShort,
        below: GestureDetector(
          onTap: () => _learnMore(context, on),
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              S.learnMore,
              style: theme.bodySmall?.copyWith(
                color: p.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        // Like the other settings a switch; on for good, so once it is on it cannot be turned off. Turning it on asks first.
        // A device without the key has a button for getting it instead
        onTap: on ? null : () => _confirm(context),
        trailing: noKey
            ? FilledButton.tonal(
                key: const ValueKey('encryption-paste'),
                style: _small,
                onPressed: () => pasteInviteSecret(context, room),
                child: Text(S.encryptionPaste),
              )
            : Switch(
                key: ValueKey(on ? 'encryption-on' : 'encryption-turn-on'),
                value: on,
                onChanged: on ? null : (_) => _confirm(context),
              ),
      ),
    );
  }

  void _learnMore(BuildContext context, bool on) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.encryptionTitle),
      content: Text(on ? S.encryptionOnHelp : S.encryptionOffHelp),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(S.close),
        ),
      ],
    ),
  );

  Future<void> _confirm(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.encryptionTitle),
        content: Text(S.encryptionConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            key: const ValueKey('encryption-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.encryptionTurnOn),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final done = await room.enableEncryption();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(done ? S.encryptionTurnedOn : S.encryptionCannot),
        ),
      );
  }
}

/// Asks for the invitation link of the room, with its key in it, and keeps the key: the way for a device that joined
/// with the code alone to read a chat that is end-to-end encrypted.
Future<void> pasteInviteSecret(BuildContext context, RoomController room) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = await showTextDialog(
    context,
    title: S.encryptionPaste,
    hint: S.encryptionPasteHint,
    maxLength: 400,
    capitalization: TextCapitalization.none,
  );
  if (text == null) return;
  final found = await room.acceptInvite(text);
  final problem = found == null
      ? S.encryptionNotALink
      : found.secret == null
      ? S.encryptionNoKeyInLink
      : null;
  if (problem != null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problem)));
  }
}
