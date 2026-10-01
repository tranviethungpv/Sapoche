import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/recent_rooms.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'code_sheet.dart';
import 'members_sheet.dart';
import 'scope.dart';
import 'widgets/qr_code_view.dart';
import 'widgets/text_dialog.dart';

/// The way into and out of a room: start one, join one, or share and manage the one this device is in.
/// [invitedCode] is a code that arrived with an invitation link.
Future<void> showRoomSheet(BuildContext context, {String? invitedCode}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RoomSheet(invitedCode: invitedCode),
    );

class _RoomSheet extends StatelessWidget {
  const _RoomSheet({this.invitedCode});

  final String? invitedCode;

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
              ? _InRoom(room: model.room)
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

  @override
  void initState() {
    super.initState();
    final invited = widget.invitedCode;
    // A link that opened the app: ask for the code sheet with the code already in it
    if (invited != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _joinTyped(invited));
    }
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

  Future<void> _create() =>
      _enter(() => widget.room.createRoom(_name.text), stayOpen: true);

  Future<void> _join(String code) =>
      _enter(() => widget.room.join(code, _name.text));

  Future<void> _joinTyped([String? invited]) async {
    if (!_requireName()) return;
    final code = await showCodeSheet(context, initialCode: invited);
    if (code != null && mounted) await _join(code);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
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
          onSubmitted: (_) => FocusScope.of(context).unfocus(),
          maxLength: 24,
          decoration: InputDecoration(hintText: S.yourName, counterText: ''),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: theme.bodySmall?.copyWith(color: p.error)),
        ],
        const SizedBox(height: 14),
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

/// In a room: its name, how to invite people, and what the owner can change.
class _InRoom extends StatelessWidget {
  const _InRoom({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final snapshot = room.snapshot;
    final code = snapshot.room ?? '';
    final link = room.inviteLink(code);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                snapshot.name ?? S.tabRoom,
                style: theme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (snapshot.canControl)
              IconButton(
                onPressed: () => _rename(context),
                tooltip: S.roomName,
                icon: Icon(
                  snapshot.name == null
                      ? Icons.add_rounded
                      : Icons.edit_outlined,
                  color: p.primary,
                ),
              ),
          ],
        ),
        if (snapshot.name == null && snapshot.canControl)
          Text(
            S.addRoomName,
            style: theme.bodySmall?.copyWith(color: p.textTertiary),
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
        Center(
          child: Text(
            S.scanToJoin,
            style: theme.bodySmall?.copyWith(color: p.textSecondary),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: room.shareInvite,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(S.invite),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _copy(context, link, S.linkCopied),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: Text(S.copyLink),
              ),
            ),
          ],
        ),
        if (snapshot.iOwn) ...[
          const SizedBox(height: 16),
          _GuestControlCard(room: room),
        ],
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.people_outline_rounded, color: p.textSecondary),
          title: Text(S.peopleInRoom),
          subtitle: Text(S.listening(snapshot.listeningCount)),
          trailing: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          onTap: () => showMembersSheet(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.logout_rounded, color: p.error),
          title: Text(S.leaveRoom, style: TextStyle(color: p.error)),
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

/// Owner only: whether guests may control the room or only add songs.
class _GuestControlCard extends StatelessWidget {
  const _GuestControlCard({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final restricted = room.snapshot.guestControl == GuestControl.add;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: restricted ? p.primaryContainer : p.surfaceRaised,
        borderRadius: BorderRadius.circular(UnisonTheme.cardRadius),
        border: Border.all(color: p.outlineSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.guestsAddOnly, style: theme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  S.guestsAddOnlyHelp,
                  style: theme.bodySmall?.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: restricted,
            onChanged: (on) =>
                room.setGuestControl(on ? GuestControl.add : GuestControl.all),
          ),
        ],
      ),
    );
  }
}
