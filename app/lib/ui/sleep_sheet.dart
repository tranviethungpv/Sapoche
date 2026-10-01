import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';

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

/// Lets the person choose when the music stops by itself.
Future<void> showSleepSheet(BuildContext context, RoomController controller) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (_) => _SleepSheet(controller: controller),
    );

class _SleepSheet extends StatelessWidget {
  const _SleepSheet({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sleep = controller.sleep;

    Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
      title: Text(label),
      trailing: selected ? Icon(Icons.check_rounded, color: p.primary) : null,
      onTap: () {
        onTap();
        Navigator.pop(context);
      },
    );

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(S.sleepTimer, style: theme.titleLarge),
          ),
          for (final minutes in sleepChoices)
            choice(
              S.sleepMinutes(minutes),
              false,
              () => controller.setSleep(SleepMode.time, minutes: minutes),
            ),
          choice(
            S.sleepSongEnd,
            sleep.mode == SleepMode.song,
            () => controller.setSleep(SleepMode.song),
          ),
          if (sleep.on)
            choice(S.sleepOff, false, () => controller.setSleep(SleepMode.off)),
          if (controller.snapshot.inRoom)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                S.sleepInRoom,
                style: theme.bodySmall?.copyWith(color: p.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
