import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'chat_sheet.dart';
import 'home_shell.dart';
import 'members_sheet.dart' show memberStatus, showMembersSheet;
import 'now_playing_page.dart' show SyncChip;
import 'player_sheet.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'widgets/appear.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/delete_background.dart';
import 'widgets/motion.dart';
import 'widgets/equalizer.dart';
import 'widgets/link_banner.dart';
import 'widgets/queued_autoplay.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/qr_code_view.dart';
import 'widgets/track_tile.dart';
import 'widgets/transport.dart';

/// What is playing and what is queued: the room's shared queue while in a room, and otherwise
/// this device's own, with the way into a room at the top.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.onAddSongs});

  final VoidCallback onAddSongs;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  /// Songs that were already on the list, so only ones that show up later animate in.
  final _known = <String>{};
  bool _seeded = false;

  VoidCallback get onAddSongs => widget.onAddSongs;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    if (!_seeded) {
      _seeded = true;
      _known.addAll(controller.snapshot.queue.map((e) => e.id));
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        // Remember what is on screen once this frame is done
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _known.addAll(snapshot.queue.map((e) => e.id)),
        );
        // The list starts below the status bar and scrolls up under it, to its glass edge
        return ScrollEdge(
          title: snapshot.inRoom ? snapshot.name ?? S.tabRoom : S.tabListen,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(height: ScrollEdge.topOf(context)),
              ),
              SliverToBoxAdapter(child: _Header(snapshot: snapshot)),
              SliverToBoxAdapter(child: LinkBanner(link: snapshot.link)),
              if (snapshot.solo)
                SliverToBoxAdapter(child: _SoloBanner(controller: controller)),
              if (snapshot.inRoom &&
                  snapshot.guestControl == GuestControl.add &&
                  !snapshot.canControl)
                const SliverToBoxAdapter(child: _GuestsAddOnlyBanner()),
              if (snapshot.phase == 'idle' &&
                  snapshot.queue.isNotEmpty &&
                  !snapshot.solo)
                SliverToBoxAdapter(
                  child: _FinishedBanner(controller: controller),
                ),
              if (snapshot.queue.isEmpty && snapshot.inRoom)
                // One card: alone, the way to get company is what the page is for; with company, the way to add songs
                SliverToBoxAdapter(
                  child: _EmptyRoom(
                    controller: controller,
                    onAddSongs: onAddSongs,
                    alone: snapshot.members.length <= 1,
                  ),
                )
              else if (snapshot.queue.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyQueue(
                    onAddSongs: onAddSongs,
                    body: snapshot.inRoom
                        ? S.emptyQueueBody
                        : S.emptyQueueBodyAlone,
                  ),
                )
              else
                ..._queueSlivers(context, controller, snapshot),
              SliverToBoxAdapter(
                child: SizedBox(height: HomeShell.bottomInsetOf(context)),
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
    final played = snapshot.queue.take(snapshot.myIndex).toList();
    final upNext = snapshot.upNext;
    return [
      if (current != null) ...[
        if (!snapshot.inRoom) _SectionTitle(S.nowPlaying),
        SliverToBoxAdapter(
          child: _swipeToRemove(
            controller,
            current,
            snapshot.inRoom
                ? _NowCard(
                    controller: controller,
                    entry: current,
                    addedBy: _adder(snapshot, current),
                  )
                : ListenableBuilder(
                    listenable: controller.playState,
                    builder: (context, _) => TrackTile(
                      track: current,
                      subtitle: _byline(current),
                      badge: _badge(snapshot, current),
                      highlight: true,
                      leadingOverlay: Equalizer(
                        active: controller.isPlaying,
                        color: Colors.white,
                      ),
                      onTap: () => controller.jump(current),
                    ),
                  ),
          ),
        ),
      ],
      if (upNext.isNotEmpty) ...[
        _SectionTitle(
          S.upNext,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  controller.shuffle();
                },
                tooltip: S.shuffle,
                icon: Icon(
                  Icons.shuffle_rounded,
                  color: context.palette.primary,
                ),
              ),
              _ClearButton(controller: controller),
            ],
          ),
        ),
        SliverReorderableList(
          itemCount: upNext.length,
          onReorderItem: (from, to) =>
              controller.move(upNext[from], snapshot.myIndex + 1 + to),
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
              background: const DeleteBackground(),
              onDismissed: (_) {
                HapticFeedback.lightImpact();
                controller.remove(entry);
              },
              child: ReorderableDelayedDragStartListener(
                index: i,
                child: Appear(
                  animate: !_known.contains(entry.id),
                  child: TrackTile(
                    track: entry,
                    subtitle: _byline(entry),
                    badge: _badge(snapshot, entry),
                    onTap: () => controller.jump(entry),
                  ),
                ),
              ),
            );
          },
        ),
      ],
      if (snapshot.autoUpNext.isNotEmpty) ...[
        _SectionTitle(S.autoplay),
        SliverToBoxAdapter(
          child: QueuedAutoplay(
            controller: controller,
            entries: snapshot.autoUpNext,
          ),
        ),
      ],
      if (played.isNotEmpty) ...[
        _SectionTitle(S.played),
        SliverList.builder(
          itemCount: played.length,
          itemBuilder: (context, i) {
            final entry = played[played.length - 1 - i];
            return _swipeToRemove(
              controller,
              entry,
              TrackTile(
                track: entry,
                subtitle: _byline(entry),
                badge: _badge(snapshot, entry),
                dimmed: true,
                // Tap to hear it again
                onTap: () => controller.jump(entry),
              ),
            );
          },
        ),
      ],
    ];
  }

  /// Swipe a row to the left to take the song off the queue.
  Widget _swipeToRemove(
    RoomController controller,
    QueueEntry entry,
    Widget child,
  ) => Dismissible(
    key: ValueKey(entry.id),
    direction: DismissDirection.endToStart,
    background: const DeleteBackground(),
    onDismissed: (_) {
      HapticFeedback.lightImpact();
      controller.remove(entry);
    },
    child: child,
  );

  /// The artist, whole: who added the song is the small picture on its cover.
  String _byline(QueueEntry entry) => entry.artist;

  /// The name of whoever added the song, for the line under it: null for a song autoplay lined up, or one whose person has
  /// left.
  String? _adder(RoomSnapshot snapshot, QueueEntry entry) {
    if (entry.auto) return null;
    final member = snapshot.members
        .where((m) => m.id == entry.addedBy)
        .firstOrNull;
    if (member == null) return null;
    return member.id == snapshot.you ? S.you : member.name;
  }

  /// Who added the song, small enough to see at a glance down the list, whatever the length of the artist's name: the
  /// person's picture, or a spark for a song that autoplay lined up (no member picked it). Nothing for a song added by
  /// somebody who has left.
  Widget? _badge(RoomSnapshot snapshot, QueueEntry entry) {
    if (entry.auto) return const AutoplayBadge();
    final member = snapshot.members
        .where((m) => m.id == entry.addedBy)
        .firstOrNull;
    if (member == null) return null;
    final who = member.id == snapshot.you ? S.you : member.name;
    return Semantics(
      label: S.addedBy(who),
      excludeSemantics: true,
      child: MemberAvatar(member: member, size: 22, ring: true),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.snapshot});

  final RoomSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  snapshot.inRoom ? snapshot.name ?? S.tabRoom : S.tabListen,
                  style: theme.headlineLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (snapshot.inRoom) ...[
                // The code is on the invitation: nowhere else on the page
                IconButton(
                  onPressed: () => showRoomSheet(context),
                  tooltip: S.invite,
                  icon: Icon(Icons.ios_share_rounded, color: p.primary),
                ),
                ChatButton(controller: AppScope.roomOf(context)),
                IconButton(
                  onPressed: () => showRoomSheet(context, settings: true),
                  tooltip: S.roomSettings,
                  icon: Icon(Icons.more_horiz_rounded, color: p.primary),
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: _RoomButton(),
                ),
            ],
          ),
        ),
        if (snapshot.inRoom) _People(snapshot: snapshot),
      ],
    );
  }
}

/// Who is in the room, as a row of large faces with a dot for what each is doing; a touch opens the list of members, and
/// the last one is the way to invite someone. With more than six the faces are smaller.
class _People extends StatefulWidget {
  const _People({required this.snapshot});

  final RoomSnapshot snapshot;

  @override
  State<_People> createState() => _PeopleState();
}

class _PeopleState extends State<_People> {
  /// Who was here when the page was drawn, and since: only somebody who comes after pops in.
  late final _known = {for (final m in widget.snapshot.members) m.id};

  RoomSnapshot get snapshot => widget.snapshot;

  @override
  Widget build(BuildContext context) {
    final fresh = {
      for (final m in snapshot.members)
        if (!_known.contains(m.id)) m.id,
    };
    // Remember them once this frame is done, so that the pop is played once
    WidgetsBinding.instance.addPostFrameCallback((_) => _known.addAll(fresh));
    final p = context.palette;
    final size = snapshot.members.length > 6 ? 44.0 : 54.0;
    // You first, then the rest as the room lists them
    final members = [
      ...snapshot.members.where((m) => m.id == snapshot.you),
      ...snapshot.members.where((m) => m.id != snapshot.you),
    ];
    return SizedBox(
      height: size + 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        children: [
          for (final member in members)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Pop(
                key: ValueKey('pop-${member.id}'),
                animate: fresh.contains(member.id),
                child: _Person(
                  member: member,
                  size: size,
                  isYou: member.id == snapshot.you,
                  loading: snapshot.phase == 'preparing' && !member.ready,
                ),
              ),
            ),
          Semantics(
            button: true,
            label: S.invite,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(size),
              onTap: () => showRoomSheet(context),
              child: SizedBox(
                width: size + 8,
                child: Column(
                  children: [
                    Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.veil,
                        border: Border.all(color: p.outline),
                      ),
                      child: Icon(Icons.add_rounded, color: p.primary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      S.inviteShort,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Person extends StatelessWidget {
  const _Person({
    required this.member,
    required this.size,
    required this.isYou,
    required this.loading,
  });

  final Member member;
  final double size;
  final bool isYou;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (status, color) = memberStatus(p, member, loading);
    final name = isYou ? S.you : member.name;
    return Semantics(
      button: true,
      label: '$name, $status',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('person-${member.id}'),
        borderRadius: BorderRadius.circular(size),
        onTap: () => showMembersSheet(context),
        child: SizedBox(
          width: size + 8,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Opacity(
                    opacity: member.away ? 0.4 : 1,
                    child: MemberAvatar(member: member, size: size, ring: true),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: p.base, width: 2),
                      ),
                    ),
                  ),
                  if (member.owner)
                    Positioned(
                      top: -6,
                      left: 0,
                      right: 0,
                      child: Icon(
                        Icons.workspace_premium_rounded,
                        size: 16,
                        color: p.primary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: member.away ? p.textTertiary : p.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The song the room is on, large enough to see from a distance: its cover, who added it, whether this device is in step
/// with the room, and a button to play or pause.
class _NowCard extends StatelessWidget {
  const _NowCard({
    required this.controller,
    required this.entry,
    required this.addedBy,
  });

  final RoomController controller;
  final QueueEntry entry;
  final String? addedBy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Material(
        color: p.surfaceRaised.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        child: InkWell(
          key: const ValueKey('room-now-card'),
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
          onTap: PlayerSheetScope.of(context).open,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
              border: Border.all(color: p.outlineSoft),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    // A video's picture cropped square and without its black bars
                    Artwork(
                      url: entry.thumb == null
                          ? null
                          : barlessThumbnail(entry.thumb!),
                      size: 64,
                      radius: 12,
                      wide: true,
                      crossfade: true,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      // The words of the next song fade in over the last one's
                      child: AnimatedSwitcher(
                        duration: Motion.of(context, Motion.medium),
                        layoutBuilder: (shown, leaving) => Stack(
                          alignment: Alignment.topLeft,
                          children: [...leaving, ?shown],
                        ),
                        child: Column(
                          key: ValueKey(entry.id),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              style: theme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                entry.artist,
                                ?(addedBy == null ? null : S.addedBy(addedBy!)),
                              ].join(' · '),
                              style: theme.bodySmall?.copyWith(
                                color: p.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: controller.playState,
                      builder: (context, _) => PlayPauseButton(
                        playing: controller.isPlaying,
                        starting: controller.isStarting,
                        onPressed: controller.togglePlay,
                        size: 44,
                      ),
                    ),
                  ],
                ),
                // Under it all, with the whole width of the card to say how this device is in step with the room
                Align(
                  alignment: Alignment.centerLeft,
                  child: ListenableBuilder(
                    listenable: controller.player,
                    builder: (context, _) => SyncChip(
                      controller: controller,
                      margin: const EdgeInsets.only(top: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the page of a room with nothing queued is: one card, as wide as a phone's even on a wide page. Alone in it, the
/// invitation comes first, as what the page is for is a friend; under it, always, a line and a button to put songs in.
class _EmptyRoom extends StatelessWidget {
  const _EmptyRoom({
    required this.controller,
    required this.onAddSongs,
    required this.alone,
  });

  final RoomController controller;
  final VoidCallback onAddSongs;
  final bool alone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final code = controller.snapshot.room ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: p.surfaceRaised.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
              border: Border.all(color: p.outlineSoft),
            ),
            child: Column(
              children: [
                if (alone) ...[
                  KeyedSubtree(
                    key: const ValueKey('room-alone'),
                    child: Column(
                      children: [
                        Text(S.listeningAlone, style: theme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          S.listeningAloneBody,
                          textAlign: TextAlign.center,
                          style: theme.bodyMedium?.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        QrCodeView(
                          data: controller.inviteLink(code),
                          size: 120,
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: controller.shareInvite,
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: Text(S.invite),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Divider(height: 1, color: p.outlineSoft),
                  ),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(S.emptyQueueTitle, style: theme.titleMedium),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: onAddSongs,
                      child: Text(S.addSongs),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The way into a room, shown while this device is on its own.
class _RoomButton extends StatelessWidget {
  const _RoomButton();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => showRoomSheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.groups_rounded, size: 18, color: p.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                S.tabRoom,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The owner has limited guests to adding songs, and this device is a guest.
class _GuestsAddOnlyBanner extends StatelessWidget {
  const _GuestsAddOnlyBanner();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: p.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.guestsAddOnlyBanner,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The queue played to its end: the songs are still here, with a way to hear them again.
class _FinishedBanner extends StatelessWidget {
  const _FinishedBanner({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                S.queueFinished,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
            IconButton(
              onPressed: controller.shuffle,
              tooltip: S.shuffle,
              icon: Icon(Icons.shuffle_rounded, color: p.onPrimaryContainer),
            ),
            FilledButton(
              onPressed: controller.togglePlay,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              child: Text(S.playAgain),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while this device listens on its own, with the way back to the room.
class _SoloBanner extends StatelessWidget {
  const _SoloBanner({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 18,
              color: p.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.soloBanner,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => controller.setSolo(false),
              child: Text(S.rejoin),
            ),
          ],
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
            title: Text(S.clearQueue),
            content: Text(S.clearQueueQuestion),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(S.cancel),
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
      child: Text(S.clear),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.onAddSongs, required this.body});

  final VoidCallback onAddSongs;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(36, 0, 36, HomeShell.bottomInsetOf(context)),
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
            body,
            textAlign: TextAlign.center,
            style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAddSongs,
            icon: const Icon(Icons.add_rounded),
            label: Text(S.addSongs),
          ),
        ],
      ),
    );
  }
}
