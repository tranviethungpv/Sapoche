import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'chat_sheet.dart';
import 'members_sheet.dart';
import 'player/lyrics_view.dart';
import 'player/up_next_view.dart';
import 'player/video_controls.dart';
import 'player_sheet.dart';
import 'song_info_sheet.dart';
import 'scope.dart';
import 'sleep_sheet.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/not_interested.dart';
import 'widgets/like_button.dart';
import 'widgets/marquee_text.dart';
import 'widgets/download_actions.dart';
import 'widgets/playlist_picker.dart';
import 'widgets/playback_bar.dart';
import 'widgets/transport.dart';
import 'widgets/video_view.dart';
import 'widgets/volume_bar.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/reactions.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Icons in the status bar and the navigation bar that show on the backdrop, light or dark like the app
    final icons = Theme.of(context).brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: icons,
        systemNavigationBarIconBrightness: icons,
      ),
      child: const _PlayerPage(),
    );
  }
}

class _PlayerPage extends StatelessWidget {
  const _PlayerPage();

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
  // Everything except the cover needs about this much height (the seek bar, the buttons, the volume, the icons); the
  // cover takes what is left. Its side margins are the ones of Apple Music, 32 on each side
  final otherContent = 460.0 * _scaleOf(media);
  return [
    min(media.size.width, _columnMax) - 2 * _margin,
    media.size.height - media.padding.vertical - otherContent,
  ].reduce((a, b) => a < b ? a : b).clamp(140.0, _columnMax - 2 * _margin);
}

/// The side margin of the full player: the cover, the title, the seek bar and the buttons all start and end on it.
const _margin = 32.0;

/// How wide the upright player's column gets. On a tablet it does not stretch across the screen: a cover that is a
/// third of the screen is out of proportion with buttons the size of a phone's.
const _columnMax = 560.0;

/// Tablets get buttons a little bigger than a phone's, so that they keep up with the cover that has room to grow.
double _scaleOf(MediaQueryData media) =>
    media.size.shortestSide >= 600 ? 1.15 : 1.0;

/// What is left under the last row of buttons, on top of the system's own bar: the icons do not sit on the edge.
const _bottomGap = 28.0;

/// What the middle of the full player shows: the cover, or one of the panels that take its place.
enum _Panel { cover, lyrics, upNext }

class _Body extends StatefulWidget {
  const _Body({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  /// Opens on the panel the player bar of a wide screen was asked for, if it was.
  late _Panel _panel = switch (PlayerSheetScope.of(context).takePanel()) {
    PlayerPanel.lyrics => _Panel.lyrics,
    PlayerPanel.upNext => _Panel.upNext,
    null => _Panel.cover,
  };

  RoomController get _c => widget.controller;

  /// A second touch on the button of the panel that is open goes back to the cover.
  void _show(_Panel panel) =>
      setState(() => _panel = _panel == panel ? _Panel.cover : panel);

  /// Whether the screen was on its side at the last look, to see the phone being turned.
  bool? _wasLandscape;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final turned = _wasLandscape == false && landscape;
    _wasLandscape = landscape;
    // A phone turned on its side while the picture plays shows it across the whole screen, as video apps do. A tablet
    // has room for the picture beside the controls.
    if (turned &&
        _c.snapshot.video &&
        media.size.shortestSide < 600 &&
        PlayerSheetScope.of(context).position.value == 1 &&
        !VideoFullScreen.open.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openVideoFullScreen(context, _c, turned: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The colours drift while the song plays, as Apple Music's do
        ListenableBuilder(
          listenable: _c.playState,
          builder: (context, _) => PlayerBackdrop(
            coverUrl: widget.current.thumb,
            moving: _c.isPlaying,
          ),
        ),
        // On its side the phone has no height for one column: the cover goes beside the controls instead. The
        // safe area also keeps both clear of a notch at the side. Reactions in the room fly up over all of it.
        ReactionShower(
          controller: _c,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) =>
                  box.maxWidth > box.maxHeight ? _wide(box) : _tall(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final current = widget.current;
    // On a tablet held upright the column does not stretch across the screen
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _columnMax),
        child: _tallColumn(p, current),
      ),
    );
  }

  Widget _tallColumn(Palette p, QueueEntry current) {
    return Column(
      children: [
        const SizedBox(height: 6),
        _Grabber(color: p.textTertiary.withValues(alpha: 0.5)),
        const SizedBox(height: 10),
        _ModePill(controller: _c),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: switch (_panel) {
              _Panel.cover => _CoverStage(
                key: const ValueKey('cover'),
                controller: _c,
                current: current,
              ),
              _ => _PanelStage(
                key: ValueKey(_panel),
                controller: _c,
                current: current,
                panel: _panel,
                onCover: () => setState(() => _panel = _Panel.cover),
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _margin),
          child: Column(
            children: [
              const SizedBox(height: 14),
              PlaybackBar(controller: _c),
              const SizedBox(height: 14),
              _TransportRow(controller: _c),
              const SizedBox(height: 6),
              VolumeBar(controller: _c),
              const SizedBox(height: 4),
              _Toolbar(controller: _c, panel: _panel, onPanel: _show),
              if (_c.snapshot.inRoom) ...[
                const SizedBox(height: 6),
                _RoomStrip(controller: _c),
              ],
              const SizedBox(height: _bottomGap),
            ],
          ),
        ),
      ],
    );
  }

  /// The cover on the left, as tall as the screen allows; the controls, or a panel in their place, on the right. The
  /// title and the row of icons stay where they are when a panel opens: only what is between them changes.
  Widget _wide(BoxConstraints box) {
    const margin = 16.0;
    // As tall as the screen allows, but not the size of a wall on a big one
    final side = (box.maxHeight - 2 * margin).clamp(
      100.0,
      (box.maxWidth * 0.46).clamp(100.0, 480.0),
    );
    // A picture keeps its own proportions, so it gets a wider place than a square cover
    final left = _c.snapshot.video
        ? (side * 16 / 9).clamp(0.0, box.maxWidth * 0.52)
        : side;
    // The cover and the controls stay together in the middle of a wide window instead of drifting to its two sides
    final gutter = ((box.maxWidth - 1040) / 2).clamp(0.0, double.infinity);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24 + gutter, vertical: margin),
      child: Row(
        children: [
          SizedBox(
            width: left,
            height: box.maxHeight - 2 * margin,
            child: Center(
              child: _CoverArt(
                controller: _c,
                current: widget.current,
                size: side,
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: _WideSide(
              controller: _c,
              current: widget.current,
              panel: _panel,
              onPanel: _show,
            ),
          ),
        ],
      ),
    );
  }
}

/// Previous, play and next: the pink disc between two plain glyphs, which is how Sapoche's player has always looked.
/// Shuffle and repeat live in Up Next, as in Apple Music.
class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.controller, this.playSize = 72});

  final RoomController controller;
  final double playSize;

  @override
  Widget build(BuildContext context) {
    final scale = _scaleOf(MediaQuery.of(context));
    return ListenableBuilder(
      listenable: controller.playState,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SkipButton(
            forward: false,
            onPressed: controller.prev,
            size: 52 * scale,
          ),
          PlayPauseButton(
            playing: controller.isPlaying,
            starting: controller.isStarting,
            onPressed: controller.togglePlay,
            size: playSize * scale,
          ),
          SkipButton(
            forward: true,
            onPressed: controller.next,
            size: 52 * scale,
          ),
        ],
      ),
    );
  }
}

/// Closes the player. The grabber of the upright player is too small a mark when the phone is on its side.
class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: PlayerSheetScope.of(context).close,
    tooltip: S.close,
    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
    color: context.palette.textSecondary,
  );
}

/// The right side of the player on its side. From top to bottom: the way out and Audio or Video, the song, then what
/// the player shows in the middle (the controls, lyrics or the queue), the row of icons, the room. Everything but the
/// middle keeps its place when a panel opens, as in Apple Music.
class _WideSide extends StatelessWidget {
  const _WideSide({
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  /// About the least height the column needs; a place shorter than this scales it down rather than overflow.
  static const _leastHeight = 380.0;

  /// The title, the controls and the icons keep 20 from the side, where the lines of the queue start.
  static Widget inset(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final scale = _scaleOf(MediaQuery.of(context));
    return LayoutBuilder(
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          // Never narrower than the row of icons needs, so that a narrow place scales it down instead
          width: box.maxWidth.clamp(340.0, 480.0 * scale),
          height: max(box.maxHeight, _leastHeight),
          child: Column(
            children: [
              inset(
                Row(
                  children: [
                    const _CloseButton(),
                    Expanded(
                      child: Center(child: _ModePill(controller: controller)),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              inset(_TitleRow(controller: controller, current: current)),
              const SizedBox(height: 4),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  // The queue has the 20 of its own at each side; lyrics get as much
                  child: switch (panel) {
                    _Panel.cover => inset(
                      _WideControls(
                        key: const ValueKey('controls'),
                        controller: controller,
                      ),
                    ),
                    _Panel.lyrics => Padding(
                      key: ValueKey(panel),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: LyricsView(controller: controller, track: current),
                    ),
                    _Panel.upNext => UpNextView(
                      key: ValueKey(panel),
                      controller: controller,
                    ),
                  },
                ),
              ),
              inset(
                _Toolbar(
                  controller: controller,
                  panel: panel,
                  onPanel: onPanel,
                ),
              ),
              if (controller.snapshot.inRoom) ...[
                const SizedBox(height: 4),
                inset(_RoomStrip(controller: controller)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the middle of the player on its side shows over the cover: the seek bar, the buttons and the volume.
class _WideControls extends StatelessWidget {
  const _WideControls({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      PlaybackBar(controller: controller),
      _TransportRow(controller: controller, playSize: 64),
      VolumeBar(controller: controller),
    ],
  );
}

/// The big cover (or the picture) with the title and the buttons that go with the song.
class _CoverStage extends StatelessWidget {
  const _CoverStage({
    super.key,
    required this.controller,
    required this.current,
  });

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final artSize = coverSize(MediaQuery.of(context));
    if (controller.snapshot.video) {
      // The picture takes all the height there is and keeps its own shape in it: a wide one is as wide as the
      // column, an upright one as tall as the place, never over the title and the controls
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: _margin),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                key: const ValueKey('video-place'),
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                child: _CoverArt(
                  controller: controller,
                  current: current,
                  size: artSize,
                ),
              ),
            ),
            _TitleRow(controller: controller, current: current),
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
          max(0.0, box.maxHeight - _titleHeight - _coverGap - 16),
        );
        // When even the title is a little too tall for the place (the keyboard is up), the block shrinks to fit
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: box.maxWidth - 2 * _margin,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: _CoverArt(
                      controller: controller,
                      current: current,
                      size: side,
                    ),
                  ),
                  // With no room left for the cover the title is all there is
                  SizedBox(height: side > 0 ? _coverGap : 0),
                  _TitleRow(controller: controller, current: current),
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

/// The cover, or the picture when the song is shown as a video. It is the same in the upright player and on its side.
class _CoverArt extends StatelessWidget {
  const _CoverArt({
    required this.controller,
    required this.current,
    required this.size,
  });

  final RoomController controller;
  final QueueEntry current;
  final double size;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    if (controller.snapshot.video) {
      return VideoView(
        key: const ValueKey('video'),
        controller: controller,
        cover: current,
        overlay: VideoControls(controller: controller),
      );
    }
    return ListenableBuilder(
      listenable: controller.playState,
      // Paused covers shrink, like in Apple Music; the shadow settles with the cover rather than jumping ahead of it
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: controller.isPlaying ? 1 : 0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Transform.scale(
          scale: 0.86 + 0.14 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14 + 0.14 * t),
                  blurRadius: 18 + 18 * t,
                  offset: Offset(0, 8 + 10 * t),
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: CoverSlot(
          controller: sheet,
          child: Artwork(
            key: sheet.pageCover,
            url: current.thumb,
            size: size,
            radius: 16,
            sharp: true,
          ),
        ),
      ),
    );
  }
}

/// A panel in place of the cover, under a small cover and the title so that the song stays in view.
class _PanelStage extends StatelessWidget {
  const _PanelStage({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onCover,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final VoidCallback onCover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_margin, 14, 20, 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: onCover,
                child: Artwork(url: current.thumb, size: 56, radius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      current.title,
                      style: theme.titleMedium,
                      rounds: MarqueeText.playerRounds,
                    ),
                    MarqueeText(
                      current.artist,
                      style: theme.bodyMedium?.copyWith(color: p.primary),
                      rounds: MarqueeText.playerRounds,
                    ),
                  ],
                ),
              ),
              LikeButton(track: current, size: 24),
              _MoreButton(controller: controller, current: current),
            ],
          ),
        ),
        Expanded(
          child: switch (panel) {
            _Panel.lyrics => Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin),
              child: LyricsView(controller: controller, track: current),
            ),
            // The queue has 20 of its own at each side, and the song above it 32: the difference is made up here
            _ => Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin - 20),
              child: UpNextView(controller: controller),
            ),
          },
        ),
      ],
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                current.title,
                style: theme.headlineSmall,
                rounds: MarqueeText.playerRounds,
              ),
              const SizedBox(height: 2),
              MarqueeText(
                current.artist,
                style: theme.titleMedium?.copyWith(
                  color: p.primary,
                  fontWeight: FontWeight.w500,
                ),
                rounds: MarqueeText.playerRounds,
              ),
            ],
          ),
        ),
        LikeButton(track: current, size: 26),
        _MoreButton(controller: controller, current: current),
      ],
    );
  }
}

/// The "…" of the song: its info, its artist, a playlist to put it in, keeping it on the phone.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  Future<void> _openArtist(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String? id;
    try {
      final radio = await AppScope.of(context).music.radio(current.videoId);
      id = radio.songOf(current.videoId)?.artistId;
    } on Object {
      // Said below
    }
    if (id == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.musicFailed)));
      return;
    }
    if (navigator.mounted) await openArtist(navigator.context, id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final library = AppScope.of(context).library;
    final snapshot = controller.snapshot;
    final who = current.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(current.addedBy);
    return PopupMenuButton<String>(
      useRootNavigator: true,
      icon: Icon(Icons.more_horiz_rounded, color: p.textSecondary),
      color: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF2B1F25),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) => switch (value) {
        'info' => showSongInfo(
          context,
          current,
          addedBy: who.isEmpty ? null : who,
        ),
        'artist' => _openArtist(context),
        'playlist' => showAddToPlaylist(context, [current]),
        'download' => startDownload(context, [current]),
        'blocked' => showNotInterested(context, current),
        _ => library.removeDownload(current.videoId),
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'info', child: Text(S.songInfo)),
        PopupMenuItem(value: 'artist', child: Text(S.goToArtist)),
        PopupMenuItem(value: 'playlist', child: Text(S.addToPlaylist)),
        ...switch (library.downloadState(current.videoId)) {
          DownloadState.done => [
            PopupMenuItem(value: 'undownload', child: Text(S.removeDownload)),
          ],
          DownloadState.queued || DownloadState.waiting => [
            PopupMenuItem(
              enabled: false,
              value: 'none',
              child: Text(S.downloading),
            ),
          ],
          _ => [PopupMenuItem(value: 'download', child: Text(S.download))],
        },
        PopupMenuItem(value: 'blocked', child: Text(S.notInterested)),
      ],
    );
  }
}

/// Lyrics, the queue, the sleep timer and where the sound goes: the things to reach for while listening.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scale = _scaleOf(MediaQuery.of(context));
    Widget button(IconData icon, String label, _Panel target) {
      final on = panel == target;
      return IconButton(
        onPressed: () => onPanel(target),
        tooltip: label,
        isSelected: on,
        icon: Icon(icon, size: 26 * scale),
        style: IconButton.styleFrom(
          foregroundColor: on ? p.onPrimary : p.textTertiary,
          backgroundColor: on ? p.primary : Colors.transparent,
          fixedSize: Size(52 * scale, 44 * scale),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        button(Icons.lyrics_outlined, S.lyrics, _Panel.lyrics),
        button(Icons.queue_music_rounded, S.upNext, _Panel.upNext),
        Flexible(child: _SleepButton(controller: controller)),
        _OutputButton(controller: controller),
      ],
    );
  }
}

/// Opens the system's list to play somewhere else than on the phone: headphones, a speaker. Its icon says where the
/// sound goes, and it is lit up while that is not the phone itself.
class _OutputButton extends StatelessWidget {
  const _OutputButton({required this.controller});

  final RoomController controller;

  static IconData _icon(String kind) => switch (kind) {
    'headphones' => Icons.headphones_rounded,
    'bluetooth' => Icons.bluetooth_audio_rounded,
    'airplay' => Icons.airplay_rounded,
    'car' => Icons.directions_car_rounded,
    'other' => Icons.speaker_group_rounded,
    _ => Icons.smartphone_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final output = controller.output;
    final away = output.kind != 'speaker';
    return IconButton(
      onPressed: controller.pickOutput,
      tooltip: output.name.isEmpty ? S.playOn : '${S.playOn} · ${output.name}',
      icon: Icon(_icon(output.kind), size: 26),
      style: IconButton.styleFrom(
        foregroundColor: away ? p.onPrimary : p.textTertiary,
        backgroundColor: away ? p.primary : Colors.transparent,
        fixedSize: const Size(52, 44),
      ),
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
    if (!sleep.on) {
      return IconButton(
        onPressed: () => showSleepSheet(context, controller),
        tooltip: S.sleepTimer,
        icon: const Icon(Icons.bedtime_outlined, size: 26),
        style: IconButton.styleFrom(
          foregroundColor: p.textTertiary,
          fixedSize: const Size(52, 44),
        ),
      );
    }
    return TextButton.icon(
      onPressed: () => showSleepSheet(context, controller),
      icon: const Icon(Icons.bedtime_outlined, size: 20),
      label: Text(
        sleepLabel(context, sleep),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: TextButton.styleFrom(
        foregroundColor: p.onPrimary,
        backgroundColor: p.primary,
        shape: const StadiumBorder(),
      ),
    );
  }
}

/// What a touch on Audio or Video does. The picture is this device's own choice and follows at once. The song also
/// changes to its other release (the music video, or the audio release) like YouTube Music's switch does: outside a
/// room for this device, in a room for everybody, because the queue is shared. A room only goes to the video
/// that way, not back: somebody else may be watching it.
Future<void> _chooseMode(BuildContext context, bool video) async {
  final controller = AppScope.roomOf(context);
  final music = AppScope.of(context).music;
  final messenger = ScaffoldMessenger.of(context);
  final snapshot = controller.snapshot;
  final current = snapshot.current;
  if (video == snapshot.video) return;
  await controller.setVideoMode(video);
  if (current == null ||
      (snapshot.inRoom && (!video || !snapshot.canControl))) {
    return;
  }
  MusicTrack? other;
  try {
    // Already the release asked for?
    if (await music.isAudioRelease(current) == !video) return;
    other = await music.otherRelease(current, video: video);
  } on Object {
    return; // no network: the picture alone
  }
  // The person may have moved on while YouTube was asked
  if (controller.snapshot.current?.id != current.id) return;
  if (other == null) {
    if (video) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.noVideoVersion)));
    }
    return;
  }
  await controller.swapVersion(current, other);
  if (snapshot.inRoom) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.videoForEveryone)));
  }
}

/// Audio or Video, like the switch at the top of YouTube Music's player: two icons, the one chosen filled.
class _ModePill extends StatelessWidget {
  const _ModePill({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final video = controller.snapshot.video;
    Widget segment(
      IconData icon,
      String label,
      bool selected,
      VoidCallback onTap,
    ) => Semantics(
      label: label,
      button: true,
      selected: selected,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 52,
            height: 32,
            decoration: BoxDecoration(
              color: selected ? p.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(
              icon,
              size: 20,
              color: selected ? p.onPrimary : p.textSecondary,
            ),
          ),
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
          segment(
            Icons.music_note_rounded,
            S.modeAudio,
            !video,
            () => _chooseMode(context, false),
          ),
          segment(
            Icons.smart_display_rounded,
            S.modeVideo,
            video,
            () => _chooseMode(context, true),
          ),
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

/// Who is listening and whether this phone is in step with them, with the ways to react and to write to them.
class _RoomStrip extends StatelessWidget {
  const _RoomStrip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    return Row(
      children: [
        // Who is here: tapping opens the list of members
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showMembersSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Semantics(
              label: S.listening(snapshot.listeningCount),
              child: AvatarStack(members: snapshot.members, size: 30, max: 3),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ListenableBuilder(
              listenable: controller.player,
              builder: (context, _) => _SyncChip(controller: controller),
            ),
          ),
        ),
        ReactButton(controller: controller),
        ChatButton(
          controller: controller,
          color: context.palette.textTertiary,
          size: 26,
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
      // Stopped on this device by something outside the app while the room plays on: say so, and play catches up
      if (!(controller.snapshot.wantsPlaying && player.heldBack)) {
        return const SizedBox.shrink();
      }
      label = S.pausedHere;
      color = p.textSecondary;
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
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
