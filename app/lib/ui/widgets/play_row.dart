import 'package:flutter/material.dart';

import '../../strings.dart';
import '../../theme/theme.dart';

/// Which of the buttons of a [PlayRow] is waiting for songs to arrive.
enum PlayWorking { none, play, shuffle, other }

/// The style of a round button beside the Play button: a soft disc that takes its colour from the page.
ButtonStyle roundButtonStyle(BuildContext context) {
  final p = context.palette;
  return IconButton.styleFrom(
    fixedSize: const Size.square(52),
    backgroundColor: p.text.withValues(alpha: 0.14),
    foregroundColor: p.text,
    shape: const CircleBorder(),
  );
}

/// A round back button, a soft disc like the other round buttons of a page.
class RoundBackButton extends StatelessWidget {
  const RoundBackButton({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(6),
    child: IconButton(
      onPressed: () => Navigator.maybePop(context),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      style: roundButtonStyle(context),
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
    ),
  );
}

/// Play, shuffle and what else can be done with the page, in the manner of Apple Music: a round shuffle button, a
/// wide Play, and [more] (a round button of the caller's, like a menu) when there is one.
class PlayRow extends StatelessWidget {
  const PlayRow({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.working = PlayWorking.none,
    this.more,
  });

  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final PlayWorking working;
  final Widget? more;

  static const _spinner = SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: onShuffle,
            tooltip: S.shuffle,
            style: roundButtonStyle(context),
            icon: working == PlayWorking.shuffle
                ? _spinner
                : const Icon(Icons.shuffle_rounded),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: onPlay,
              style: FilledButton.styleFrom(
                backgroundColor: p.text,
                foregroundColor: p.base,
                shape: const StadiumBorder(),
              ),
              icon: working == PlayWorking.play
                  ? _spinner
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(S.play),
            ),
          ),
          if (more != null) ...[const SizedBox(width: 12), more!],
        ],
      ),
    );
  }
}
