import 'package:flutter/material.dart';

import '../../strings.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';

/// Which of the buttons of a [PlayRow] is waiting for songs to arrive.
enum PlayWorking { none, play, shuffle, other }

/// The style of a round button beside the Play button: a soft disc that takes its colour from the page.
ButtonStyle roundButtonStyle(BuildContext context, {double size = 52}) {
  final p = context.palette;
  return IconButton.styleFrom(
    fixedSize: Size.square(size),
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
    // An app bar gives its leading 56: with 4 round it the button is 48, the least to touch
    padding: const EdgeInsets.all(4),
    child: IconButton(
      onPressed: () => Navigator.maybePop(context),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      style: roundButtonStyle(context),
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
    ),
  );
}

/// Play, shuffle and what else can be done with the page, in the manner of Apple Music: a round shuffle button, a
/// wide Play, then [download] and [more] (round buttons of the caller's, like a menu) when there are.
class PlayRow extends StatelessWidget {
  const PlayRow({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.working = PlayWorking.none,
    this.more,
    this.download,
    this.inline = false,
  });

  /// Beside a cover, on a wide screen: the row is no wider than [_inlineMax], and starts at the left, instead of Play
  /// taking the width of the page.
  final bool inline;

  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final PlayWorking working;
  final Widget? more;

  /// Keeps the page's songs on the phone (an `OfflineButton`).
  final Widget? download;

  /// The widest an [inline] row gets: Play takes what the round buttons leave, up to this.
  static const _inlineMax = 420.0;

  /// The round buttons are this wide, with this between them (see `roundButtonStyle`).
  static const _round = 52.0;
  static const _gap = 12.0;

  /// The least Play is given to keep its word: with less it is a round button.
  static const _playLeast = 112.0;

  /// On a screen on its side, where the player takes a share of the width and the pages are narrow, Play is a round button
  /// unless it has this much room: a pill that is only a little wider than the round ones beside it looks squeezed.
  static const _playRoomy = 200.0;

  /// A column narrower than this puts the round buttons under Play.
  static const _stackBelow = 380.0;

  static const _spinner = SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shuffle = IconButton(
      onPressed: onShuffle,
      tooltip: S.shuffle,
      style: roundButtonStyle(context),
      icon: working == PlayWorking.shuffle
          ? _spinner
          : const Icon(Icons.shuffle_rounded),
    );
    FilledButton playButton({required bool narrow}) => FilledButton.icon(
      onPressed: onPlay,
      style: FilledButton.styleFrom(
        backgroundColor: p.text,
        foregroundColor: p.base,
        shape: const StadiumBorder(),
        // Beside a cover with four buttons, the narrower Play keeps them in the column at large text
        padding: narrow ? EdgeInsets.symmetric(horizontal: download == null ? 32 : 20) : null,
      ),
      icon: working == PlayWorking.play
          ? _spinner
          : const Icon(Icons.play_arrow_rounded),
      // In the narrow column beside a cover Play may be given less than its words: they shrink rather than overflow
      label: narrow ? FittedBox(fit: BoxFit.scaleDown, child: Text(S.play)) : Text(S.play),
    );
    Widget buttons({required bool narrow}) => LayoutBuilder(
      builder: (context, box) {
        // What the round buttons leave Play. Squeezed under [_playLeast] (the player beside the pages, a phone on its
        // side) it is a round button as well, with the triangle only, rather than a pill that shrinks its word
        final others = 1 + (download == null ? 0 : 1) + (more == null ? 0 : 1);
        final room = box.maxWidth - others * (_round + _gap);
        final wide = HomeShell.isWide(context);
        // Beside a cover in a window on its side the column is the cover's width: Play is round there whatever the count of
        // the buttons (an artist has only Shuffle, so a playlist's 200 dp of room would leave it a pill among round ones)
        final round = room < (wide ? _playRoomy : _playLeast) || (inline && wide);
        return Row(
          mainAxisAlignment: round && !inline
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            shuffle,
            const SizedBox(width: _gap),
            if (round)
              IconButton(
                onPressed: onPlay,
                tooltip: S.play,
                style: roundButtonStyle(context).copyWith(
                  backgroundColor: WidgetStatePropertyAll(p.text),
                  foregroundColor: WidgetStatePropertyAll(p.base),
                ),
                icon: working == PlayWorking.play
                    ? _spinner
                    : const Icon(Icons.play_arrow_rounded, size: 30),
              )
            else
              Expanded(child: playButton(narrow: narrow)),
            if (download != null) ...[const SizedBox(width: _gap), download!],
            if (more != null) ...[const SizedBox(width: _gap), more!],
          ],
        );
      },
    );
    if (!inline) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
        child: buttons(narrow: false),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _inlineMax),
        child: LayoutBuilder(
          builder: (context, box) {
            // Four buttons in a column as narrow as the cover leave Play little: it takes the whole width, and the
            // round ones go under it. Not on a phone on its side, which has no height to spare, and not in a window on
            // its side at all (a tablet, a browser): there Play is a round button among the others, whatever the height
            final stacked =
                box.maxWidth < _stackBelow &&
                (download != null || more != null) &&
                MediaQuery.sizeOf(context).height >= 480 &&
                !HomeShell.isWide(context);
            if (!stacked) return buttons(narrow: true);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                playButton(narrow: false),
                const SizedBox(height: 12),
                Row(
                  children: [
                    shuffle,
                    if (download != null) ...[const SizedBox(width: 12), download!],
                    if (more != null) ...[const SizedBox(width: 12), more!],
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
