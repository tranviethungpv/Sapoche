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

/// Lets the person choose when the music stops by itself.
Future<void> showSleepSheet(BuildContext context, RoomController controller) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: Motion.sheet(context),
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

    // The rows are made as those of the room's settings are (`SheetTile`), in the same margins
    Widget choice(
      IconData icon,
      String label,
      bool selected,
      VoidCallback onTap,
    ) => SheetTile(
      icon: icon,
      title: label,
      trailing: selected ? Icon(Icons.check_rounded, color: p.primary) : null,
      onTap: () {
        onTap();
        Navigator.pop(context);
      },
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(S.sleepTimer, style: theme.headlineSmall),
            const SizedBox(height: 8),
            for (final minutes in sleepChoices)
              choice(
                Icons.timer_outlined,
                S.sleepMinutes(minutes),
                false,
                () => controller.setSleep(SleepMode.time, minutes: minutes),
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
                  maxLength: 3,
                  digits: true,
                );
                final minutes = int.tryParse(typed ?? '');
                // A day is the longest it is worth: past that the number is a slip of the finger
                if (minutes == null || minutes < 1 || minutes > 1440) return;
                await controller.setSleep(SleepMode.time, minutes: minutes);
                if (navigator.mounted) navigator.pop();
              },
            ),
            choice(
              Icons.music_note_rounded,
              S.sleepSongEnd,
              sleep.mode == SleepMode.song,
              () => controller.setSleep(SleepMode.song),
            ),
            if (sleep.on)
              choice(
                Icons.timer_off_outlined,
                S.sleepOff,
                false,
                () => controller.setSleep(SleepMode.off),
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
  }
}
