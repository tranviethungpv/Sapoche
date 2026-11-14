import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../theme/theme.dart';

/// What a snack bar says when a song did not start here: a picture for the kind of trouble, what happened in a few words,
/// and under it what it means for the person, so that a slow connection or a song YouTube does not give out is not taken
/// for a broken app.
class PlayProblemNote extends StatelessWidget {
  const PlayProblemNote(this.problem, {super.key});

  final PlayProblem problem;

  /// How long it stays: it has two lines to read, and the first of them may be the only sign that something is going on.
  static const duration = Duration(seconds: 8);

  static IconData iconOf(String code) => switch (code) {
    'load_slow' => Icons.hourglass_top_rounded,
    'load_offline' => Icons.wifi_off_rounded,
    'load_skipped' || 'load_unplayable' => Icons.music_off_rounded,
    'load_broken' => Icons.signal_wifi_bad_rounded,
    _ => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: '${problem.headline}. ${problem.detail}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(iconOf(problem.code), size: 22, color: p.onSnack),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    problem.headline,
                    style: text.bodyMedium?.copyWith(
                      color: p.onSnack,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    problem.detail,
                    style: text.bodyMedium?.copyWith(color: p.onSnack),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
