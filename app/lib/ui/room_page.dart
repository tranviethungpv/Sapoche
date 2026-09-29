import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/avatars.dart';
import 'widgets/equalizer.dart';
import 'widgets/link_banner.dart';
import 'widgets/track_tile.dart';

/// The room: who is here and the shared queue.
class RoomPage extends StatelessWidget {
  const RoomPage({super.key, required this.onAddSongs});

  final VoidCallback onAddSongs;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        return SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(child: _Header(snapshot: snapshot)),
              SliverToBoxAdapter(child: LinkBanner(link: snapshot.link)),
              if (snapshot.queue.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyQueue(onAddSongs: onAddSongs),
                )
              else
                ..._queueSlivers(context, controller, snapshot),
              const SliverToBoxAdapter(
                child: SizedBox(height: HomeShell.bottomInset),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _queueSlivers(
    BuildContext context,
    RoomController controller,
    RoomSnapshot snapshot,
  ) {
    final current = snapshot.current;
    final played = snapshot.queue.take(snapshot.index).toList();
    final upNext = snapshot.upNext;
    return [
      if (current != null) ...[
        const _SectionTitle(S.nowPlaying),
        SliverToBoxAdapter(
          child: ListenableBuilder(
            listenable: controller.player,
            builder: (context, _) => TrackTile(
              track: current,
              subtitle: _byline(snapshot, current),
              highlight: true,
              leadingOverlay: Equalizer(
                active: controller.isPlaying,
                color: Colors.white,
              ),
              onTap: () => controller.jump(current),
            ),
          ),
        ),
      ],
      if (upNext.isNotEmpty) ...[
        _SectionTitle(S.upNext, action: _ClearButton(controller: controller)),
        SliverReorderableList(
          itemCount: upNext.length,
          onReorderItem: (from, to) =>
              controller.move(upNext[from], snapshot.index + 1 + to),
          proxyDecorator: (child, _, animation) => Material(
            color: Colors.transparent,
            elevation: 0,
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.02).animate(animation),
              child: child,
            ),
          ),
          itemBuilder: (context, i) {
            final entry = upNext[i];
            return Dismissible(
              key: ValueKey(entry.id),
              direction: DismissDirection.endToStart,
              background: const _DeleteBackground(),
              onDismissed: (_) {
                HapticFeedback.lightImpact();
                controller.remove(entry);
              },
              child: ReorderableDelayedDragStartListener(
                index: i,
                child: TrackTile(
                  track: entry,
                  subtitle: _byline(snapshot, entry),
                  onTap: () => controller.jump(entry),
                ),
              ),
            );
          },
        ),
      ],
      if (played.isNotEmpty) ...[
        const _SectionTitle(S.played),
        SliverList.builder(
          itemCount: played.length,
          itemBuilder: (context, i) {
            final entry = played[played.length - 1 - i];
            return TrackTile(
              track: entry,
              subtitle: _byline(snapshot, entry),
              dimmed: true,
              onTap: () => controller.jump(entry),
            );
          },
        ),
      ],
    ];
  }

  String _byline(RoomSnapshot snapshot, QueueEntry entry) {
    final who = entry.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(entry.addedBy);
    return who.isEmpty ? entry.artist : '${entry.artist} · ${S.addedBy(who)}';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.snapshot});

  final RoomSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(S.tabRoom, style: theme.headlineLarge)),
              _CodeChip(code: snapshot.room ?? ''),
              IconButton(
                onPressed: AppScope.roomOf(context).shareInvite,
                tooltip: S.invite,
                icon: Icon(Icons.ios_share_rounded, color: p.primary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              AvatarStack(members: snapshot.members),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  S.listening(snapshot.members.length),
                  style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          Clipboard.setData(ClipboardData(text: code));
          HapticFeedback.selectionClick();
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text(S.codeCopied)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: p.onPrimaryContainer,
                  letterSpacing: 2.5,
                  fontFeatures: const [],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, size: 15, color: p.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.titleLarge),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text(S.clearQueue),
            content: const Text(S.clearQueueQuestion),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(S.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  S.clear,
                  style: TextStyle(color: context.palette.error),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) controller.clearQueue();
      },
      child: const Text(S.clear),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 28),
      color: p.error.withValues(alpha: 0.16),
      child: Icon(Icons.delete_outline_rounded, color: p.error),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.onAddSongs});

  final VoidCallback onAddSongs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 36, HomeShell.bottomInset),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: p.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.queue_music_rounded, size: 42, color: p.primary),
          ),
          const SizedBox(height: 22),
          Text(S.emptyQueueTitle, style: theme.titleLarge),
          const SizedBox(height: 8),
          Text(
            S.emptyQueueBody,
            textAlign: TextAlign.center,
            style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAddSongs,
            icon: const Icon(Icons.add_rounded),
            label: const Text(S.addSongs),
          ),
        ],
      ),
    );
  }
}
