import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';
import 'up_next_view.dart';
import '../widgets/artwork.dart';
import '../widgets/edge_fade.dart';
import '../widgets/like_button.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_bar.dart';
import '../widgets/volume_bar.dart';
import 'look.dart';
import 'parts.dart';
import '../widgets/motion.dart';

/// Side of the full player's cover. It depends only on the screen, so the cover can be decoded
/// at this size before the player is ever opened.
double coverSize(MediaQueryData media, {double margin = playerMargin, bool docked = false}) {
  final across = min(media.size.width, playerColumnMax) - 2 * margin;
  // Beside the pages the card is as tall as the window and the stage that holds the cover measures what height is left
  // (`PlayerCoverStage`): only the width is asked here
  if (docked) return across.clamp(140.0, playerColumnMax - 2 * margin);
  // Everything except the cover needs about this much height (the seek bar, the buttons, the volume, the icons); the
  // cover takes what is left. Its side margins are the ones of Apple Music, 32 on each side
  final otherContent = 460.0 * playerScale(media);
  return min(across, media.size.height - media.padding.vertical - otherContent)
      .clamp(140.0, playerColumnMax - 2 * margin);
}

/// The side margin of the full player: the cover, the title, the seek bar and the buttons all start and end on it.
const playerMargin = 32.0;

/// The same beside the pages, in a card that is only a third of a tablet's width.
const playerDockMargin = 16.0;

/// How wide the upright player's column gets. On a tablet it does not stretch across the screen: a cover that is a
/// third of the screen is out of proportion with buttons the size of a phone's.
const playerColumnMax = 560.0;

/// What is left under the last row of buttons, on top of the system's own bar: the icons do not sit on the edge.
const playerBottomGap = 28.0;

/// A player shorter than this (a phone on its side) has no height for the upright column and draws the small one.
const playerCompactHeight = 480.0;

/// The card beside the pages is short in a window that is wide and not tall (a laptop, a TV at 960x540 dp): under this
/// the upright column would leave the cover a few dp, so it draws the small player too, which has the volume and the icons
/// in the "…" of the song.
const playerDockCompactHeight = 620.0;

/// Whether a player [height] dp tall, drawn here, is the small one.
bool playerIsCompact(BuildContext context, double height) =>
    height <
    (PlayerLookScope.dockedOf(context)
        ? playerDockCompactHeight
        : playerCompactHeight);

/// The most the small player grows across: beside a wide window it stays a column.
const playerCompactWidthMax = 560.0;

/// The player as Sapoche has always drawn it: the cover in the middle of an upright column, which the small one of a
/// phone on its side folds into a shorter one.
class ClassicPlayer extends StatelessWidget {
  const ClassicPlayer({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;

  /// What the middle of the player shows.
  final NowPlayingPanel panel;

  /// A touch on the button of a panel: a second touch on the open one goes back to the cover.
  final ValueChanged<NowPlayingPanel> onPanel;

  /// Shows that panel, whatever is open.
  final ValueChanged<NowPlayingPanel> onChoose;

  RoomController get _c => controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => playerIsCompact(context, box.maxHeight)
        ? _compact(context)
        : _tall(context),
  );

  /// The player of a phone on its side, a column that is short: the cover as large as the height leaves it, the song with
  /// Audio or Video beside its heart, the seek bar with its times in one line, the buttons with Lyrics and Up next at either
  /// end of them. What there is no room for (the volume, the row of icons) is in the "…" of the song. A panel takes the
  /// place of the cover under a line with the song.
  Widget _compact(BuildContext context) {
    final cover = panel == NowPlayingPanel.cover;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerCompactWidthMax),
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Column(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.of(context, 240),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  child: cover
                      ? Padding(
                          key: const ValueKey('cover'),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: CompactCover(controller: _c, current: current),
                        )
                      : PlayerPanelStage(
                          key: ValueKey(panel),
                          controller: _c,
                          current: current,
                          panel: panel,
                          onCover: () => onChoose(NowPlayingPanel.cover),
                          compact: true,
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    if (cover) ...[
                      const SizedBox(height: 4),
                      PlayerTitleRow(
                        controller: _c,
                        current: current,
                        dense: true,
                        extra: ModeToggle(controller: _c),
                      ),
                    ],
                    const SizedBox(height: 6),
                    PlaybackBar(controller: _c, inline: true),
                    const SizedBox(height: 2),
                    CompactTransport(
                      controller: _c,
                      leading: PanelButton(
                        icon: Icons.lyrics_outlined,
                        label: S.lyrics,
                        target: NowPlayingPanel.lyrics,
                        panel: panel,
                        onPanel: onPanel,
                      ),
                      trailing: PanelButton(
                        icon: Icons.queue_music_rounded,
                        label: S.upNext,
                        target: NowPlayingPanel.upNext,
                        panel: panel,
                        onPanel: onPanel,
                      ),
                    ),
                    if (_c.snapshot.inRoom)
                      RoomStrip(controller: _c, compact: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final docked = PlayerLookScope.dockedOf(context);

    // On a tablet held upright the column does not stretch across the screen
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerColumnMax),
        child: _tallColumn(context, p, current, docked: docked),
      ),
    );
  }

  Widget _tallColumn(
    BuildContext context,
    Palette p,
    QueueEntry current, {
    required bool docked,
  }) {
    // Beside the pages the card is narrow and the cover is all it has to show: its margins are smaller
    final margin = docked ? playerDockMargin : playerMargin;
    return Column(
      children: [
        // Beside the pages the player is not pulled down: no handle
        if (docked)
          const SizedBox(height: 14)
        else ...[
          const SizedBox(height: 6),
          PlayerGrabber(color: p.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
        ],
        ModePill(controller: _c),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.of(context, 240),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: switch (panel) {
              NowPlayingPanel.cover => PlayerCoverStage(
                key: const ValueKey('cover'),
                controller: _c,
                current: current,
                margin: margin,
                // The card has no height to spare: the cover has what these would take
                gap: docked ? 16 : _coverGap,
                bottom: docked ? 6 : 16,
              ),
              _ => PlayerPanelStage(
                key: ValueKey(panel),
                controller: _c,
                current: current,
                panel: panel,
                onCover: () => onChoose(NowPlayingPanel.cover),
              ),
            },
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: margin),
          child: Column(
            children: [
              SizedBox(height: docked ? 8 : 14),
              PlaybackBar(controller: _c),
              SizedBox(height: docked ? 8 : 14),
              TransportRow(controller: _c),
              const SizedBox(height: 6),
              // A browser has no volume of its own to set: the tab follows the computer's
              // Not while the lyrics or the queue are open: the queue gets the room (it shows a row more); the bar is
              // there again with the cover
              if (!kIsWeb && panel == NowPlayingPanel.cover)
                VolumeBar(controller: _c),
              const SizedBox(height: 4),
              PlayerToolbar(controller: _c, panel: panel, onPanel: onPanel),
              if (_c.snapshot.inRoom) ...[
                const SizedBox(height: 6),
                RoomStrip(controller: _c),
              ],
              SizedBox(height: docked ? 14 : playerBottomGap),
            ],
          ),
        ),
      ],
    );
  }
}

/// The big cover (or the picture) with the title and the buttons that go with the song. The other styles of the upright
/// player use it too.
class PlayerCoverStage extends StatelessWidget {
  const PlayerCoverStage({
    super.key,
    required this.controller,
    required this.current,
    this.margin = playerMargin,
    this.showMore = true,
    this.gap = _coverGap,
    this.bottom = 16,
    this.between,
    this.betweenGap = 0,
    this.lowered = false,
  });

  final RoomController controller;
  final QueueEntry current;

  /// The space at each side of the cover and of the song under it.
  final double margin;

  /// Whether the "…" of the song stands in the title's row.
  final bool showMore;

  /// The space between the cover and the title, and what is kept free under the title.
  final double gap;
  final double bottom;

  /// Something between the cover and the title (the running lines of the lyrics). Its height is in [bottom].
  final Widget? between;

  /// The space between [between] and the title under it. It is in [bottom] too.
  final double betweenGap;

  /// The block of the cover and the song stands at the foot of its place, next to the seek bar, and what room there is
  /// over is above the cover, not round it.
  final bool lowered;

  @override
  Widget build(BuildContext context) {
    final docked = PlayerLookScope.dockedOf(context);
    final artSize = coverSize(MediaQuery.of(context), margin: margin, docked: docked);
    if (controller.snapshot.video) {
      // The picture takes all the height there is and keeps its own shape in it: a wide one is as wide as the
      // column, an upright one as tall as the place, never over the title and the controls
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: margin),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                key: const ValueKey('video-place'),
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                child: PlayerCoverArt(
                  controller: controller,
                  current: current,
                  size: artSize,
                ),
              ),
            ),
            if (between != null) ...[between!, SizedBox(height: betweenGap)],
            PlayerTitleRow(
              controller: controller,
              current: current,
              showMore: showMore,
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // The cover and the title under it are one block, in the middle of the place above the controls, as in Apple
        // Music. The title keeps its size and the cover is what gives way when the screen is short
        final side = min(
          artSize,
          max(0.0, box.maxHeight - _titleHeight - gap - bottom),
        );
        // A lowered block has what room is over above it; half of that goes between the cover and what is under it
        // instead, so that the cover is not left far from the top of its place. The lines the title can take are counted
        final twoLines =
            side >= artSize &&
            box.maxHeight - side - gap - _titleHeight - bottom >= 32;
        final slack =
            box.maxHeight -
            side -
            gap -
            _titleHeight -
            bottom -
            (twoLines ? 32 : 0);
        final lift = lowered && side >= artSize ? max(0.0, slack) / 2 : 0.0;
        // When even the title is a little too tall for the place (the keyboard is up), the block shrinks to fit
        return Align(
          alignment: lowered ? Alignment.bottomCenter : Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: box.maxWidth - 2 * margin,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: PlayerCoverArt(
                      controller: controller,
                      current: current,
                      size: side,
                    ),
                  ),
                  // With no room left for the cover the title is all there is
                  SizedBox(height: side > 0 ? gap + lift : 0),
                  if (between != null) ...[
                    between!,
                    SizedBox(height: betweenGap),
                  ],
                  PlayerTitleRow(
                    controller: controller,
                    current: current,
                    showMore: showMore,
                    // A second line is for a screen where the cover keeps its size with it: one line of the title is
                    // taller than [_titleHeight] by about 32 dp
                    wrapLines: twoLines ? 2 : 1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// About the height of the title, the artist and the heart under the cover.
const _titleHeight = 64.0;

/// The space between the cover and the title under it.
const _coverGap = 28.0;

/// A panel in place of the cover, under a small cover and the title so that the song stays in view. The other styles of
/// the upright player use it too.
class PlayerPanelStage extends StatelessWidget {
  const PlayerPanelStage({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onCover,
    this.compact = false,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final VoidCallback onCover;

  /// The small player of a phone on its side: the cover and the song are one line of 40, and the panel has all the rest.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final look = PlayerLookScope.of(context);
    final margin = PlayerLookScope.dockedOf(context) ? playerDockMargin : playerMargin;
    final side = compact ? 16.0 : margin;
    return Column(
      children: [
        Padding(
          padding: compact
              ? const EdgeInsets.fromLTRB(16, 0, 12, 6)
              : EdgeInsets.fromLTRB(margin, 14, 20, 8),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: S.showCover,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: onCover,
                  // Even in a browser's Video mode: YouTube asks for a frame of 200 pixels, which is not the room a small
                  // cover has, so the frame is hidden here (it plays on) as it is in Audio and under the closed player
                  child: Artwork(
                    url: current.thumb,
                    size: compact ? 40 : 56,
                    radius: compact ? 6 : 10,
                  ),
                ),
              ),
              SizedBox(width: compact ? 8 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      current.title,
                      style: compact
                          ? theme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            )
                          : theme.titleMedium,
                      rounds: MarqueeText.playerRounds,
                    ),
                    MarqueeText(
                      current.artist,
                      style: (compact ? theme.bodySmall : theme.bodyMedium)
                          ?.copyWith(
                            color: look.quietArtist ? p.textSecondary : p.link,
                          ),
                      rounds: MarqueeText.playerRounds,
                    ),
                  ],
                ),
              ),
              LikeButton(
                track: current,
                size: compact ? 22 : 24,
                star: look.star,
              ),
              PlayerMoreButton(
                controller: controller,
                current: current,
                compact: compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (panel) {
            // The lines go up under the song above them: they fade out there, not cut off at its foot
            NowPlayingPanel.lyrics => EdgeFade(
              top: 24,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: LyricsView(controller: controller, track: current),
              ),
            ),
            NowPlayingPanel.comments => Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: CommentsView(controller: controller, track: current),
            ),
            // The queue has 20 of its own at each side, and the song above it 32: the difference is made up here
            _ => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 0 : max(0.0, margin - 20),
              ),
              child: UpNextView(controller: controller),
            ),
          },
        ),
      ],
    );
  }
}
