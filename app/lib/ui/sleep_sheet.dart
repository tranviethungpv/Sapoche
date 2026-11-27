import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/motion.dart';
import 'widgets/sheet_tile.dart';
import 'widgets/text_dialog.dart';

/// Minutes on offer for the sleep timer.
const sleepChoices = [15, 30, 45, 60, 90];

/// What the button of the sleep timer says while it is set.
String sleepLabel(BuildContext context, SleepState sleep) =>
    switch (sleep.mode) {
      SleepMode.time => S.sleepStopsAt(
        TimeOfDay.fromDateTime(sleep.endsAt!).format(context),
      ),
      SleepMode.song => S.sleepStopsAfterSong,
      SleepMode.off => S.sleepTimer,
    };

/// The time of day, as the phone writes it (24 hours or AM/PM).
String sleepClock(BuildContext context, DateTime at) =>
    TimeOfDay.fromDateTime(at).format(context);

/// The clock the sheet reads; a test sets it to a fixed hour.
@visibleForTesting
DateTime Function() sleepNow = DateTime.now;

/// When the music would stop at the end of this song: now plus what is left of it at the speed it plays. Null while
/// the length of the song is not known.
DateTime? sleepSongEndsAt(RoomController controller) {
  final total = controller.durationMs();
  if (total <= 0) return null;
  final speed = controller.player.value.speed;
  final left = (total - controller.positionMs()).clamp(0, total);
  return sleepNow().add(
    Duration(milliseconds: (left / (speed > 0 ? speed : 1)).round()),
  );
}

/// The line of the sleep timer in the "..." menu: the hour it stops at while one is set.
String sleepMenuLabel(BuildContext context, RoomController controller) {
  final sleep = controller.sleep;
  return switch (sleep.mode) {
    SleepMode.time => S.sleepTimerAt(sleepClock(context, sleep.endsAt!)),
    SleepMode.song => S.sleepTimerAt(S.sleepSongEndShort),
    SleepMode.off => S.sleepTimer,
  };
}

/// Lets the person choose when the music stops by itself.
Future<void> showSleepSheet(BuildContext context, RoomController controller) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: Motion.sheet(context),
      builder: (_) => _SleepSheet(controller: controller),
    );

class _SleepSheet extends StatefulWidget {
  const _SleepSheet({required this.controller});

  final RoomController controller;

  @override
  State<_SleepSheet> createState() => _SleepSheetState();
}

class _SleepSheetState extends State<_SleepSheet> {
  // The hours and what is left move on while the sheet is open
  Timer? _tick;

  RoomController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sleep = controller.sleep;
        final now = sleepNow();

        // The rows are made as those of the room's settings are (`SheetTile`), in the same margins
        Widget choice(
          IconData icon,
          String label,
          VoidCallback onTap, {
          bool selected = false,
          String? at,
        }) => SheetTile(
          icon: selected ? Icons.check_rounded : icon,
          title: label,
          detail: at,
          onTap: () {
            onTap();
            Navigator.pop(context);
          },
        );

        String at(int minutes) =>
            sleepClock(context, now.add(Duration(minutes: minutes)));
        final songEnd = sleepSongEndsAt(controller);

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(S.sleepTimer, style: theme.headlineSmall),
                const SizedBox(height: 8),
                if (sleep.on) ...[
                  _Status(controller: controller, now: now),
                  const SizedBox(height: 8),
                ],
                for (final minutes in sleepChoices)
                  choice(
                    Icons.timer_outlined,
                    S.sleepMinutes(minutes),
                    () => controller.setSleep(SleepMode.time, minutes: minutes),
                    at: at(minutes),
                  ),
                SheetTile(
                  key: const ValueKey('sleep-custom'),
                  icon: Icons.edit_outlined,
                  title: S.sleepCustom,
                  chevron: true,
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    final typed = await showTextDialog(
                      context,
                      title: S.sleepCustom,
                      hint: S.sleepCustomHint,
                      maxLength: 4,
                      digits: true,
                      helper: (text) {
                        final minutes = int.tryParse(text);
                        return minutes == null || minutes < 1 || minutes > 1440
                            ? null
                            : S.sleepStatusAt(at(minutes));
                      },
                    );
                    final minutes = int.tryParse(typed ?? '');
                    // A day is the longest it is worth: past that the number is a slip of the finger
                    if (minutes == null || minutes < 1 || minutes > 1440) {
                      return;
                    }
                    await controller.setSleep(SleepMode.time, minutes: minutes);
                    if (navigator.mounted) navigator.pop();
                  },
                ),
                choice(
                  Icons.music_note_rounded,
                  S.sleepSongEnd,
                  () => controller.setSleep(SleepMode.song),
                  selected: sleep.mode == SleepMode.song,
                  at: songEnd == null
                      ? null
                      : S.sleepAround(sleepClock(context, songEnd)),
                ),
                if (controller.snapshot.inRoom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                    child: Text(
                      S.sleepInRoom,
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// While a timer is set: the hour the music stops at and how long is left, with the way to turn it off.
class _Status extends StatelessWidget {
  const _Status({required this.controller, required this.now});

  final RoomController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sleep = controller.sleep;
    final song = sleep.mode == SleepMode.song;
    final endsAt = song ? sleepSongEndsAt(controller) : sleep.endsAt;
    final left = endsAt?.difference(now);
    final title = song
        ? S.sleepStatusSong
        : S.sleepStatusAt(sleepClock(context, sleep.endsAt!));
    final line = left == null ? null : S.sleepLeft(left, clock: song);
    return Container(
      key: const ValueKey('sleep-status'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: p.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.bedtime_rounded, color: p.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.titleMedium?.copyWith(
                    color: p.onPrimaryContainer,
                  ),
                ),
                if (line != null)
                  Text(
                    line,
                    style: theme.bodyMedium?.copyWith(
                      color: p.onPrimaryContainer,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('sleep-off'),
            onPressed: () {
              controller.setSleep(SleepMode.off);
              Navigator.pop(context);
            },
            child: Text(S.sleepOff),
          ),
        ],
      ),
    );
  }
}
