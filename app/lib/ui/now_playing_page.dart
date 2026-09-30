import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'members_sheet.dart';
import 'player_sheet.dart';
import 'scope.dart';
import 'sleep_sheet.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/like_button.dart';
import 'widgets/playlist_picker.dart';
import 'widgets/playback_bar.dart';
import 'widgets/transport.dart';
import 'widgets/video_view.dart';
import 'widgets/player_backdrop.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    return PlayerPull(
      child: KeyedSubtree(
        key: sheet.pageRoot,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final current = controller.snapshot.current;
              if (current == null) {
                // The queue emptied while the sheet was open
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => sheet.close(),
                );
                return const SizedBox.shrink();
              }
              return _Body(controller: controller, current: current);
            },
          ),
        ),
      ),
    );
  }
}

/// Side of the full player's cover. It depends only on the screen, so the cover can be decoded
/// at this size before the player is ever opened.
double coverSize(MediaQueryData media) {
  // Everything except the cover needs about this much height; the cover takes what is left
  const otherContent = 436.0;
  return [
    media.size.width - 64,
    380.0,
    media.size.height - media.padding.vertical - otherContent,
  ].reduce((a, b) => a < b ? a : b).clamp(140.0, 380.0);
}

class _Body extends StatelessWidget {
  const _Body({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sheet = PlayerSheetScope.of(context);
    final artSize = coverSize(MediaQuery.of(context));

    return Stack(
      fit: StackFit.expand,
      children: [
        PlayerBackdrop(coverUrl: current.thumb),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const SizedBox(height: 6),
                _Grabber(color: p.textTertiary.withValues(alpha: 0.5)),
                const SizedBox(height: 10),
                _ModePill(controller: controller),
                const Spacer(flex: 2),
                if (controller.snapshot.video)
                  VideoView(
                    key: const ValueKey('video'),
                    controller: controller,
                    cover: current,
                  )
                else
                  ListenableBuilder(
                    listenable: controller.player,
                    builder: (context, _) => AnimatedScale(
                      // Paused covers shrink, like in Apple Music
                      scale: controller.isPlaying ? 1 : 0.86,
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutBack,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: controller.isPlaying ? 0.28 : 0.14,
                              ),
                              blurRadius: controller.isPlaying ? 36 : 18,
                              offset: Offset(0, controller.isPlaying ? 18 : 8),
                            ),
                          ],
                        ),
                        child: CoverSlot(
                          controller: sheet,
                          child: Artwork(
                            key: sheet.pageCover,
                            url: current.thumb,
                            size: artSize,
                            radius: 16,
                            sharp: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(flex: 2),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            current.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.headlineSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            current.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.titleMedium?.copyWith(
                              color: p.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => showAddToPlaylist(context, [current]),
                      tooltip: S.addToPlaylist,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 42,
                        height: 42,
                      ),
                      icon: Icon(
                        Icons.playlist_add_rounded,
                        size: 26,
                        color: p.textTertiary,
                      ),
                    ),
                    LikeButton(track: current, size: 26),
                    _RepeatButton(controller: controller),
                  ],
                ),
                const SizedBox(height: 14),
                PlaybackBar(controller: controller),
                const SizedBox(height: 10),
                ListenableBuilder(
                  listenable: controller.player,
                  builder: (context, _) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SkipButton(
                        forward: false,
                        onPressed: controller.prev,
                        size: 52,
                      ),
                      PlayPauseButton(
                        playing: controller.isPlaying,
                        starting: controller.isStarting,
                        onPressed: controller.togglePlay,
                      ),
                      SkipButton(
                        forward: true,
                        onPressed: controller.next,
                        size: 52,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                _SleepButton(controller: controller),
                const Spacer(),
                if (controller.snapshot.inRoom)
                  _RoomStrip(controller: controller),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens the sleep timer; lit up, with the hour it stops at, while one is set.
class _SleepButton extends StatelessWidget {
  const _SleepButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sleep = controller.sleep;
    return TextButton.icon(
      onPressed: () => showSleepSheet(context, controller),
      icon: Icon(Icons.bedtime_outlined, size: 20),
      label: Text(sleepLabel(context, sleep)),
      style: TextButton.styleFrom(
        foregroundColor: sleep.on ? p.primary : p.textTertiary,
        backgroundColor: sleep.on ? p.primaryContainer : Colors.transparent,
        shape: const StadiumBorder(),
      ),
    );
  }
}

/// Cycles off, repeat all, repeat this song. Lit up while repeating.
class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mode = controller.snapshot.repeat;
    final on = mode != Repeat.off;
    return Tooltip(
      message: switch (mode) {
        Repeat.off => S.repeatOff,
        Repeat.all => S.repeatAll,
        Repeat.one => S.repeatOne,
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? p.primaryContainer : Colors.transparent,
        ),
        child: IconButton(
          onPressed: controller.cycleRepeat,
          icon: Icon(
            mode == Repeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
          ),
          color: on ? p.onPrimaryContainer : p.textTertiary,
        ),
      ),
    );
  }
}

/// Audio or Video, like the switch at the top of YouTube Music's player. A choice for this device only.
class _ModePill extends StatelessWidget {
  const _ModePill({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final video = controller.snapshot.video;
    Widget segment(String label, bool selected, VoidCallback onTap) =>
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? p.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: selected ? p.onPrimary : p.textSecondary),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(S.modeAudio, !video, () => controller.setVideoMode(false)),
          segment(S.modeVideo, video, () => controller.setVideoMode(true)),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 5,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// Who is listening and whether this phone is in step with them.
class _RoomStrip extends StatelessWidget {
  const _RoomStrip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final snapshot = controller.snapshot;
    return Row(
      children: [
        // Who is here: tapping opens the list of members
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showMembersSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  AvatarStack(members: snapshot.members, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      S.listening(snapshot.listeningCount),
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: controller.player,
          builder: (context, _) => _SyncChip(controller: controller),
        ),
      ],
    );
  }
}

/// Within this many ms of the room counts as in sync (the drift control aims well inside it).
const _inSyncMs = 80;

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final player = controller.player.value;
    final drift = player.driftMs;
    final String label;
    final Color color;
    if (controller.snapshot.solo) {
      label = S.onYourOwn;
      color = p.primary;
    } else if (!controller.isPlaying) {
      return const SizedBox.shrink();
    } else if (controller.isStarting) {
      label = S.buffering;
      color = p.textSecondary;
    } else if (drift == null) {
      label = S.syncing;
      color = p.textSecondary;
    } else if (drift.abs() <= _inSyncMs) {
      label = '${S.inSync} · ${formatDrift(drift)}';
      color = p.success;
    } else {
      // Off by an audible amount: the drift control is bringing this phone back
      label = '${S.catchingUp} · ${formatDrift(drift)}';
      color = p.textSecondary;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMembersSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
