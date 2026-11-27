import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../player_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/playback_bar.dart';
import '../widgets/volume_bar.dart';
import '../widgets/whole_pixel_clip.dart';
import 'classic_player.dart';
import 'look.dart';
import 'lyrics_ticker.dart';
import 'parts.dart';
import '../widgets/motion.dart';

/// The player of the style of the full cover: the cover runs across the whole width at the top and melts into the
/// colours behind it, the buttons are plain glyphs with no disc, and the row of icons has the lyrics, where the sound
/// goes and the queue (the comments and the sleep timer are in the "…" of the song). With a picture to show, a panel
/// open, the places are the classic player's, with this style's look. On a screen on its side the cover runs across the
/// whole width of the player and up to its top edge, whatever the height.
class AppleMusicPlayer extends StatelessWidget {
  const AppleMusicPlayer({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;
  final ValueChanged<NowPlayingPanel> onChoose;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => playerIsCompact(context, box.maxHeight)
        ? _compact(context)
        : _tall(context),
  );

  /// A phone on its side: the cover across the player and up to its top, melting into the colours behind it, with the
  /// song over its foot; the seek bar in one line and the buttons with Lyrics and Up next at the ends of them. A picture
  /// is as wide as the player at its top, and a panel takes the place of the cover under a line with the song.
  Widget _compact(BuildContext context) {
    final video = controller.snapshot.video;
    final cover = panel == NowPlayingPanel.cover;
    final inRoom = controller.snapshot.inRoom;
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          const SizedBox(height: 8),
          PlaybackBar(controller: controller, inline: true),
          const SizedBox(height: 2),
          CompactTransport(
            controller: controller,
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
          if (inRoom) RoomStrip(controller: controller, compact: true),
        ],
      ),
    );
    if (!cover) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: playerCompactWidthMax),
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 8),
            child: Column(
              children: [
                Expanded(
                  child: PlayerPanelStage(
                    key: ValueKey(panel),
                    controller: controller,
                    current: current,
                    panel: panel,
                    onCover: () => onChoose(NowPlayingPanel.cover),
                    compact: true,
                  ),
                ),
                controls,
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerCompactWidthMax),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              Expanded(
                child: _CompactCover(
                  controller: controller,
                  current: current,
                  video: video,
                ),
              ),
              controls,
            ],
          ),
        ),
      ),
    );
  }

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final inset = MediaQuery.paddingOf(context).top;
    // The cover runs up under the status bar; with a picture to show or a panel open the way out is the grabber, as in
    // the classic player
    final bleed = panel == NowPlayingPanel.cover && !controller.snapshot.video;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerColumnMax * 1.5),
        child: Column(
          children: [
            if (!bleed) ...[
              SizedBox(height: inset),
              // The way out in the middle and the button for Audio or Video on the right
              SizedBox(
                height: 44,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Beside the pages the player is not pulled down: no handle
                    if (!PlayerLookScope.dockedOf(context))
                      PlayerGrabber(
                        color: p.textTertiary.withValues(alpha: 0.5),
                      ),
                    Positioned(
                      right: 12,
                      child: ModeToggle(controller: controller),
                    ),
                  ],
                ),
              ),
            ],
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.of(context, 240),
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: switch (panel) {
                  // A picture keeps its own frame, with margins, as in the classic player
                  NowPlayingPanel.cover when controller.snapshot.video =>
                    PlayerCoverStage(
                      key: const ValueKey('cover'),
                      controller: controller,
                      current: current,
                      margin: _margin,
                    ),
                  NowPlayingPanel.cover => _FullCover(
                    key: const ValueKey('cover'),
                    controller: controller,
                    current: current,
                  ),
                  _ => PlayerPanelStage(
                    key: ValueKey(panel),
                    controller: controller,
                    current: current,
                    panel: panel,
                    onCover: () => onChoose(NowPlayingPanel.cover),
                  ),
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin),
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  // The lines of the lyrics, running, above the seek bar
                  if (panel == NowPlayingPanel.cover &&
                      !controller.snapshot.video)
                    LyricsTicker(controller: controller, track: current),
                  const SizedBox(height: 6),
                  PlaybackBar(
                    controller: controller,
                    middle: controller.snapshot.video || kIsWeb
                        ? null
                        : _Quality(controller: controller),
                  ),
                  const SizedBox(height: 6),
                  TransportRow(controller: controller),
                  const SizedBox(height: 6),
                  if (!kIsWeb && panel == NowPlayingPanel.cover)
                    VolumeBar(controller: controller),
                  const SizedBox(height: 4),
                  PlayerToolbar(
                    controller: controller,
                    panel: panel,
                    onPanel: onPanel,
                  ),
                  DeviceLine(controller: controller),
                  if (controller.snapshot.inRoom) ...[
                    const SizedBox(height: 6),
                    RoomStrip(controller: controller),
                  ],
                  const SizedBox(height: playerBottomGap),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The space at each side of the bars, the buttons and the song.
const _margin = 22.0;

/// [value] cut down to a whole number of device pixels. A mask that ends part-way through a pixel row leaves that row
/// partly unmasked, and the picture's last row then shows as a thin line across the screen (on a tablet whose pixel
/// ratio is not a whole number, the Tab S7); the same is done for the glow of `PlayerBackdrop`.
double _wholePixels(BuildContext context, double value) {
  final scale = MediaQuery.devicePixelRatioOf(context);
  return (value * scale).floor() / scale;
}

/// The cover across the whole width and as tall as the place gives it, its foot melting into what is behind; the song
/// stands over that foot, so that nothing is left empty between the cover and the seek bar.
class _FullCover extends StatelessWidget {
  const _FullCover({
    super.key,
    required this.controller,
    required this.current,
  });

  final RoomController controller;
  final QueueEntry current;

  /// How far below the status bar the blur fades out.
  static const _blurFade = 40.0;

  /// The mask of the blur: full at the top, then easing off to nothing (a smooth step, in nine stops).
  static const _ease = [
    Color(0xFF000000),
    Color(0xF7000000),
    Color(0xE0000000),
    Color(0xB8000000),
    Color(0x80000000),
    Color(0x48000000),
    Color(0x1F000000),
    Color(0x07000000),
    Color(0x00000000),
  ];

  /// How far the song stands over the foot of the cover.
  static const _overlap = 56.0;

  /// About the height of the title, the artist and the star, and the gap above them (more with larger text).
  static double _titleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(64.0) + 12;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, box) {
        // The picture fills the width and what height there is, cropped to it; not taller than 1.4 of its width, where
        // the screen is much taller than it is wide
        final height = _wholePixels(
          context,
          min(
            box.maxWidth * 1.4,
            max(0.0, box.maxHeight - _titleHeight(context) + _overlap),
          ),
        );
        return SizedBox(
          height: box.maxHeight,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: height,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF000000),
                      Color(0xFF000000),
                      Color(0x00000000),
                    ],
                    stops: [0, 0.45, 0.9],
                  ).createShader(rect),
                  child: CoverSlot(
                    controller: sheet,
                    child: _CoverPicture(
                      pageCover: sheet.pageCover,
                      url: current.thumb,
                      width: box.maxWidth,
                      height: height,
                    ),
                  ),
                ),
              ),
              // Under the status bar the picture is blurred and a little darkened, so that the time and the notices on it
              // are not lost in the picture. The blur is a blurred copy of the cover laid over the sharp one, and it is
              // let through by a mask that thins out by an easing curve, so that the sharp picture comes up out of the
              // blur with no line where it begins
              if (top > 0) ...[
                // Not at the minimum of effects: the blur and its mask are two layers drawn over the picture
                if (!context.flat)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: _wholePixels(context, top + _blurFade),
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: _ease,
                      ).createShader(rect),
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minHeight: height,
                          maxHeight: height,
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: 12,
                              sigmaY: 12,
                              tileMode: TileMode.clamp,
                            ),
                            child: Artwork(
                              url: current.thumb,
                              size: height,
                              width: box.maxWidth,
                              radius: 0,
                              sharp: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // A little dark that thins out the same way
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: top + _blurFade,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Without the blur the dark carries the time and the notices alone, so it is stronger
                        colors: context.flat
                            ? const [
                                Color(0xA6000000),
                                Color(0x85000000),
                                Color(0x57000000),
                                Color(0x2E000000),
                                Color(0x0F000000),
                                Color(0x00000000),
                              ]
                            : const [
                                Color(0x73000000),
                                Color(0x5C000000),
                                Color(0x3A000000),
                                Color(0x1C000000),
                                Color(0x08000000),
                                Color(0x00000000),
                              ],
                        stops: const [0, 0.2, 0.45, 0.7, 0.88, 1],
                      ),
                    ),
                  ),
                ),
              ],
              // Audio or Video, on the picture, under the status bar
              Positioned(
                top: top + 4,
                right: 12,
                child: ModeToggle(controller: controller, onPicture: true),
              ),
              // The way out, on the picture: not beside the pages, where the player is not pulled down
              if (!PlayerLookScope.dockedOf(context))
                Positioned(
                  top: top + 6,
                  left: 0,
                  right: 0,
                  child: const Center(
                    child: PlayerGrabber(color: Color(0xB3FFFFFF)),
                  ),
                ),
              Positioned(
                left: _margin,
                right: _margin,
                top: max(0.0, height - _overlap),
                child: PlayerTitleRow(controller: controller, current: current),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The picture of the full cover, [width] by [height]. A place wider than tall (the card of a tablet, or beside the
/// pages on a phone on its side) shows the picture square, as wide as the place and cut at the top and foot: a wide crop
/// of a square cover held in the black of a 16:9 thumbnail would show the black at the sides, and the square's edges.
class _CoverPicture extends StatelessWidget {
  const _CoverPicture({
    required this.pageCover,
    required this.url,
    required this.width,
    required this.height,
  });

  final GlobalKey pageCover;
  final String? url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final side = max(height, width);
    // The key is on the part that shows, which is where the cover flies to
    // The foot is left undrawn by a pixel row or two: the mask ends in a part row where the box stands at a half pixel,
    // and what is drawn there shows as a line across the cover (on the phone and the Tab S7)
    return WholePixelClip(
      key: pageCover,
      child: OverflowBox(
        minHeight: side,
        maxHeight: side,
        child: Artwork(
          url: url,
          size: side,
          width: width,
          radius: 0,
          sharp: true,
          crossfade: true,
        ),
      ),
    );
  }
}

/// The cover of a phone on its side: across the whole width and up to the top edge, its foot melting into the colours
/// behind it, with the song over that foot. A picture (the video) is 16 to 9 across the width at the top instead, and
/// the song is under it.
class _CompactCover extends StatelessWidget {
  const _CompactCover({
    required this.controller,
    required this.current,
    required this.video,
  });

  final RoomController controller;
  final QueueEntry current;
  final bool video;

  /// The song stands this high over the foot of the cover.
  static const _overlap = 34.0;

  /// The song's line: the title and the artist.
  static const _titleHeight = 48.0;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final title = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: PlayerTitleRow(
            controller: controller,
            current: current,
            dense: true,
          ),
        );
        if (video) {
          // The picture keeps its shape across the width; the song is under it
          return Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxHeight * 16 / 9,
                        ),
                        child: PlayerCoverArt(
                          controller: controller,
                          current: current,
                          size: box.maxWidth,
                        ),
                      ),
                    ),
                  ),
                  title,
                ],
              ),
              Positioned(
                top: 8,
                right: 10,
                child: ModeToggle(controller: controller, onPicture: true),
              ),
            ],
          );
        }
        final height = _wholePixels(
          context,
          max(0.0, box.maxHeight - _titleHeight + _overlap),
        );
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: height,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF000000),
                    Color(0xFF000000),
                    Color(0x00000000),
                  ],
                  stops: [0, 0.52, 1],
                ).createShader(rect),
                child: CoverSlot(
                  controller: sheet,
                  child: _CoverPicture(
                    pageCover: sheet.pageCover,
                    url: current.thumb,
                    width: box.maxWidth,
                    height: height,
                  ),
                ),
              ),
            ),
            // Audio or Video, on the picture
            Positioned(
              top: 8,
              right: 10,
              child: ModeToggle(controller: controller, onPicture: true),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: max(0.0, height - _overlap),
              child: title,
            ),
          ],
        );
      },
    );
  }
}

/// The actual codec, bitrate and sample rate of the stream or file playing right now, in the line between the two
/// times. Hidden until the player knows what it is playing (and never shown on the web, where YouTube's frame hides it).
class _Quality extends StatelessWidget {
  const _Quality({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerPosition>(
      valueListenable: controller.player,
      builder: (context, position, _) {
        final fmt = position.audioFormat;
        final full = fmt?.format() ?? '';
        if (fmt == null || full.isEmpty) return const SizedBox.shrink();
        final p = context.palette;
        final style = Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: p.textSecondary);
        // Drop the sample rate whole (then fall back to codec) on narrow / 1.3x screens instead of cutting "48 k…"
        final short = fmt.format(includeHz: false);
        final candidates = <String>[
          full,
          if (short.isNotEmpty && short != full) short,
          if (fmt.codec != null && fmt.codec!.isNotEmpty && fmt.codec != short)
            fmt.codec!,
        ];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: LayoutBuilder(
            builder: (context, box) {
              // 14dp icon + 4dp gap = 18dp beside the label
              final textMax = max(0.0, box.maxWidth - 18);
              final merged = DefaultTextStyle.of(context).style.merge(style);
              String chosen = candidates.last;
              for (final text in candidates) {
                final w = (TextPainter(
                  text: TextSpan(text: text, style: merged),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: 1,
                )..layout()).width;
                if (w <= textMax) {
                  chosen = text;
                  break;
                }
              }
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 14,
                    color: p.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      chosen,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
