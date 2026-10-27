import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'members_sheet.dart' show confirmRemoveMember, memberStatus;
import 'profile_sheet.dart';
import 'scope.dart';
import 'widgets/artwork.dart';
import 'widgets/avatar_zoom.dart';
import 'widgets/avatars.dart';

/// Who someone in the room is: their picture, big and to be zoomed, and what they are doing.
Future<void> showMemberProfile(BuildContext context, String memberId) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => AppScope(
        model: AppScope.of(context),
        child: _MemberProfile(memberId: memberId),
      ),
    );

class _MemberProfile extends StatelessWidget {
  const _MemberProfile({required this.memberId});

  final String memberId;

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final model = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([room, model.settings]),
      builder: (context, _) {
        final snapshot = room.snapshot;
        final member = snapshot.members
            .where((m) => m.id == memberId)
            .firstOrNull;
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('member-profile'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: member == null
                ? _Gone()
                : _Body(
                    room: room,
                    snapshot: snapshot,
                    member: member,
                    image: member.id == snapshot.you
                        ? model.settings.avatar
                        : room.avatarOf(member.id),
                  ),
          ),
        );
      },
    );
  }
}

class _Gone extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Center(
      child: Text(
        S.profileGone,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: context.palette.textSecondary),
      ),
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({
    required this.room,
    required this.snapshot,
    required this.member,
    required this.image,
  });

  final RoomController room;
  final RoomSnapshot snapshot;
  final Member member;
  final dynamic image;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final isYou = member.id == snapshot.you;
    final loading = snapshot.phase == 'preparing' && !member.ready;
    final (status, color) = memberStatus(p, member, loading);
    final queued = snapshot.queue.where((e) => e.addedBy == member.id).length;
    return Column(
      children: [
        GestureDetector(
          key: const ValueKey('profile-view-photo'),
          // Only a picture can be looked at closer
          onTap: image == null
              ? null
              : () => showAvatarZoom(context, name: member.name, image: image),
          child: Stack(
            children: [
              Avatar(name: member.name, size: 120, image: image),
              if (image != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: p.surfaceRaised,
                      shape: BoxShape.circle,
                      border: Border.all(color: p.outlineSoft),
                    ),
                    child: Icon(
                      Icons.zoom_in_rounded,
                      size: 18,
                      color: p.primary,
                      semanticLabel: S.viewPhoto,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          member.name,
          textAlign: TextAlign.center,
          style: text.headlineSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            if (member.owner) _Chip(S.owner, Icons.workspace_premium_rounded),
            if (isYou) _Chip(S.you, Icons.person_rounded),
            _Chip(status, null, dot: color),
          ],
        ),
        const SizedBox(height: 20),
        _Doing(snapshot: snapshot, member: member, loading: loading),
        if (queued > 0) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              S.profileQueued(queued),
              style: text.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (isYou)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('profile-view-edit'),
              onPressed: () {
                Navigator.pop(context);
                showProfileSheet(context);
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(S.profileEdit),
            ),
          )
        else if (snapshot.iOwn)
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const ValueKey('profile-view-remove'),
              onPressed: () => confirmRemoveMember(context, room, member),
              icon: Icon(
                Icons.person_remove_outlined,
                color: p.error,
                size: 18,
              ),
              label: Text(S.removeFromRoom, style: TextStyle(color: p.error)),
            ),
          ),
      ],
    );
  }
}

/// What they are listening to. Only the room's song is known: someone on their own plays what the room does not see.
class _Doing extends StatelessWidget {
  const _Doing({
    required this.snapshot,
    required this.member,
    required this.loading,
  });

  final RoomSnapshot snapshot;
  final Member member;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final song = snapshot.index < snapshot.queue.length
        ? snapshot.queue[snapshot.index]
        : null;
    final (title, line) = member.away
        ? (S.profileListeningTo, S.profileAwayNote)
        : member.solo
        ? (S.profileListeningTo, S.profileAloneNote)
        : song == null || snapshot.phase == 'idle'
        ? (S.profileListeningTo, S.profileNothing)
        : (S.profileListeningTo, null);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.veil,
        borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.labelLarge?.copyWith(color: p.textSecondary)),
          const SizedBox(height: 8),
          if (line != null)
            Text(line, style: text.bodyMedium)
          else
            Row(
              children: [
                Artwork(url: song!.thumb, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: p.textSecondary),
                      ),
                      if (loading)
                        Text(
                          S.statusLoading,
                          style: text.bodySmall?.copyWith(
                            color: p.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.icon, {this.dot});

  final String label;
  final IconData? icon;

  /// A dot of this colour in place of an icon.
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: p.veilStrong,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, size: 14, color: p.primary),
          if (dot != null)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
