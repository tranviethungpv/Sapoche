import 'package:flutter/material.dart';

import '../data/music_models.dart';
import '../strings.dart';
import 'home_shell.dart';
import 'player/player_message.dart';
import 'scope.dart';
import 'widgets/ambient_backdrop.dart';
import 'widgets/music_shelf.dart';
import 'widgets/page_width.dart';
import 'widgets/play_row.dart';

/// Opens what YouTube Music has for a mood in the tab that is showing, with a way back.
Future<void> openMood(BuildContext context, MoodChip chip) {
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  return TabNavigation.push(
    context,
    MaterialPageRoute<void>(builder: (_) => MoodScreen(chip: chip)),
  );
}

/// The playlists that suit a mood (Relax, Workout...), in rows that scroll sideways.
class MoodScreen extends StatefulWidget {
  const MoodScreen({super.key, required this.chip});

  final MoodChip chip;

  @override
  State<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends State<MoodScreen> {
  Future<MusicHome>? _home;

  void _load() {
    _home = AppScope.of(context).music.home(params: widget.chip.params);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_home == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: const RoundBackButton(),
          title: Text(widget.chip.label),
        ),
        body: PageWidth(
          child: FutureBuilder<MusicHome>(
            future: _home,
            builder: (context, async) {
              if (async.hasError) {
                return PlayerMessage(
                  icon: Icons.cloud_off_rounded,
                  text: S.moodFailed,
                  action: S.tryAgain,
                  onAction: () => setState(_load),
                );
              }
              final shelves = async.data?.shelves;
              if (shelves == null) {
                return const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                );
              }
              return ListView(
                padding: EdgeInsets.only(
                  bottom: HomeShell.bottomInsetOf(context),
                ),
                children: [
                  for (final shelf in shelves) MusicShelfView(shelf: shelf),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
