import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/avatars.dart';

/// Who is in the room, what each of them is doing, and whether this device follows the room.
void showMembersSheet(BuildContext context) {
  final controller = AppScope.roomOf(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _MembersSheet(controller: controller),
  );
}

class _MembersSheet extends StatelessWidget {
  const _MembersSheet({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final members = _sorted(snapshot);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.membersTitle, style: theme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  snapshot.awayCount == 0
                      ? S.listening(snapshot.listeningCount)
                      : '${S.listening(snapshot.listeningCount)} · ${S.awayCount(snapshot.awayCount)}',
                  style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: 16),
                _FollowCard(controller: controller, solo: snapshot.solo),
                const SizedBox(height: 8),
                for (final member in members)
                  _MemberRow(
                    member: member,
                    isYou: member.id == snapshot.you,
                    loading: snapshot.phase == 'preparing' && !member.ready,
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: controller.shareInvite,
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text(S.invite),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// You first, then people who are listening, then those on their own, then those who are away.
  List<Member> _sorted(RoomSnapshot snapshot) {
    int rank(Member m) => m.id == snapshot.you
        ? 0
        : m.away
        ? 3
        : m.solo
        ? 2
        : 1;
    return [...snapshot.members]..sort((a, b) => rank(a).compareTo(rank(b)));
  }
}

/// The switch that decides whether the room's play, pause and skip move this device.
class _FollowCard extends StatelessWidget {
  const _FollowCard({required this.controller, required this.solo});

  final RoomController controller;
  final bool solo;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: solo ? p.primaryContainer : p.surfaceRaised,
        borderRadius: BorderRadius.circular(UnisonTheme.cardRadius),
        border: Border.all(color: p.outlineSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.listenTogether, style: theme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  solo ? S.listenTogetherOff : S.listenTogetherOn,
                  style: theme.bodySmall?.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: !solo,
            onChanged: (together) => controller.setSolo(!together),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isYou,
    required this.loading,
  });

  final Member member;
  final bool isYou;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final (status, color) = member.away
        ? (S.statusAway, p.textTertiary)
        : member.solo
        ? (S.statusAlone, p.primary)
        : loading
        ? (S.statusLoading, p.textSecondary)
        : (S.statusListening, p.success);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Opacity(
            opacity: member.away ? 0.4 : 1,
            child: Avatar(name: member.name, size: 40),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              isYou ? '${member.name} (${S.you})' : member.name,
              style: theme.titleMedium?.copyWith(
                color: member.away ? p.textTertiary : p.text,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(status, style: theme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}
