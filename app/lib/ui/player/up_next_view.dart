import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../widgets/touch_box.dart';
import '../widgets/focus_nav.dart';
import '../widgets/menu_lines.dart';
import '../widgets/delete_background.dart';
import '../widgets/edge_fade.dart';
import '../widgets/queued_autoplay.dart';
import '../widgets/track_tile.dart';
import 'player_message.dart';
import 'track_section.dart';
import '../widgets/motion.dart';

/// What plays after this song: the queue, which can be put in another order or thinned out, then what would
/// play once it runs out, as Apple Music's Up Next does with its Autoplay.
class UpNextView extends StatelessWidget {
  const UpNextView({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final upNext = snapshot.upNext;
        final current = snapshot.current;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: LayoutBuilder(
                builder: (context, box) {
                  final autoplay =
                      !snapshot.inRoom || snapshot.roomAutoplay != null;
                  // The three are one size: when the longest word does not fit its pill all three give their words up
                  // and keep the icons (the tooltips say what each does), instead of one shrinking more than the others
                  final words = _pillWordsFit(context, box.maxWidth, autoplay);
                  return Row(
                    children: [
                      Expanded(
                        child: ShuffleButton(
                          controller: controller,
                          words: words,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RepeatButton(
                          controller: controller,
                          words: words,
                        ),
                      ),
                      if (autoplay) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: _AutoplayButton(
                            controller: controller,
                            words: words,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            // The last row is not cut off where the list ends: it fades out (the page behind is tinted by the cover, so
            // this is a mask, not a veil of the plain background)
            Expanded(
              child: EdgeFade(
                bottom: 28,
                child: _list(context, snapshot, upNext, current),
              ),
            ),
          ],
        );
      },
    );
  }

  /// What dragging and swiping do to a row of the queue, as lines of a menu: up, down, to the top, out.
  Future<void> _rowMenu(
    BuildContext row,
    QueueEntry entry,
    int i,
    int count,
    void Function(int from, int to) onReorder,
  ) async {
    final value = await showLinesMenu(row, [
      MenuLine(
        'next',
        Icons.vertical_align_top_rounded,
        S.playNext,
        enabled: i > 0,
      ),
      MenuLine('up', Icons.arrow_upward_rounded, S.moveUp, enabled: i > 0),
      MenuLine(
        'down',
        Icons.arrow_downward_rounded,
        S.moveDown,
        enabled: i < count - 1,
      ),
      MenuLine(
        'remove',
        Icons.delete_outline_rounded,
        S.removeFromQueue,
        apart: true,
      ),
    ]);
    switch (value) {
      case 'next':
        onReorder(i, 0);
      case 'up':
        onReorder(i, i - 1);
      case 'down':
        onReorder(i, i + 1);
      case 'remove':
        HapticFeedback.lightImpact();
        controller.remove(entry);
    }
  }

  void _clearQueued(BuildContext context, List<QueueEntry> queued) {
    final cleared = [...queued];
    if (cleared.isEmpty) return;
    HapticFeedback.selectionClick();
    controller.clearQueued();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(S.queueCleared),
          action: SnackBarAction(
            label: S.undo,
            onPressed: () => controller.addMany(cleared),
          ),
          duration: const Duration(milliseconds: 4000),
        ),
      );
  }

  Widget _queuedHeading(BuildContext context, List<QueueEntry> queued) =>
      SectionHeading(
        S.nextInQueue,
        action: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: () => _clearQueued(context, queued),
          child: Text(S.clear),
        ),
      );

  Widget _list(
    BuildContext context,
    RoomSnapshot snapshot,
    List<QueueEntry> upNext,
    QueueEntry? current,
  ) {
    final inRoom = snapshot.inRoom;
    final queued = snapshot.queuedUpNext;
    final contextList = snapshot.contextUpNext;
    final label = snapshot.label;
    final contextTitle =
        !inRoom && label != null && label.isNotEmpty ? S.nextFrom(label) : S.upNext;
    final twoGroups = !inRoom && queued.isNotEmpty && contextList.isNotEmpty;
    final itemCount = upNext.length + (twoGroups ? 1 : 0);

    void onReorder(int from, int to) {
      if (inRoom) {
        controller.move(upNext[from], snapshot.myIndex + 1 + to);
        return;
      }
      if (!twoGroups) {
        controller.move(
          upNext[from],
          snapshot.myIndex + 1 + to,
          queued: queued.isNotEmpty,
        );
        return;
      }
      final divider = queued.length;
      if (from == divider) return;
      final entry = upNext[from < divider ? from : from - 1];
      // After taking the dragged row out, the divider sits at divider - 1 when the row came from above it, else at divider
      final dividerAfter = from < divider ? divider - 1 : divider;
      final intoQueued = to <= dividerAfter;
      final songIndex = intoQueued ? to : to - 1;
      controller.move(
        entry,
        snapshot.myIndex + 1 + songIndex,
        queued: intoQueued,
      );
    }

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        // With nothing queued and autoplay on, "Up next" and "nothing is queued" are not said twice over: the one line
        // "Autoplay · plays after your queue" under the buttons is all there is above the suggestions, which are then
        // what the screen is for
        if (inRoom) ...[
          if (!(upNext.isEmpty && snapshot.roomAutoplay != null))
            SliverToBoxAdapter(child: SectionHeading(S.upNext)),
          // Said whenever nothing is queued and autoplay is not there to say it: a heading with nothing under it reads as
          // broken
          if (upNext.isEmpty && snapshot.roomAutoplay == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  S.nothingAfter,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: context.palette.textSecondary),
                ),
              ),
            ),
        ] else if (queued.isNotEmpty)
          SliverToBoxAdapter(child: _queuedHeading(context, queued))
        else if (contextList.isNotEmpty)
          SliverToBoxAdapter(child: SectionHeading(contextTitle)),
        SliverReorderableList(
          itemCount: itemCount,
          onReorderItem: onReorder,
          proxyDecorator: (child, _, animation) => Material(
            color: Colors.transparent,
            elevation: 0,
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.02).animate(animation),
              child: child,
            ),
          ),
          itemBuilder: (context, i) {
            if (twoGroups && i == queued.length) {
              return SectionHeading(
                contextTitle,
                key: const ValueKey('context-heading'),
              );
            }
            final entry =
                upNext[twoGroups && i > queued.length ? i - 1 : i];
            return Dismissible(
              key: ValueKey(entry.id),
              direction: DismissDirection.endToStart,
              background: const DeleteBackground(),
              onDismissed: (_) {
                HapticFeedback.lightImpact();
                controller.remove(entry);
              },
              // Dragging and swiping are for a finger: a remote holds OK (or presses Menu) for the same four things
              child: Builder(
                builder: (row) => MenuKeys(
                  onMenu: () => _rowMenu(row, entry, i, itemCount, onReorder),
                  child: ReorderableDelayedDragStartListener(
                    index: i,
                    child: TrackTile(
                      track: entry,
                      onTap: () => controller.jump(entry),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (current != null)
          SliverToBoxAdapter(
            child: _Suggestions(controller: controller, current: current),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// Whether the words of the three pills fit in a pill each, at the size they are drawn: the icon, a gap and the word,
/// between the padding of the pill.
bool _pillWordsFit(BuildContext context, double width, bool autoplay) {
  final style = Theme.of(context).textTheme.labelLarge;
  final words = [S.shuffle, S.repeat, if (autoplay) S.autoplay];
  final pill = (width - 10 * (words.length - 1)) / words.length;
  for (final word in words) {
    final painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final needed = 8 + 24 + 6 + painter.width + 8;
    painter.dispose();
    if (needed > pill) return false;
  }
  return true;
}

/// Shuffle, on or off. On, what is still to come is mixed and stays mixed as songs are added; off, the songs go back in
/// their order. A room whose server is too old for that has only a one-time mix: the icon turns once and a note says
/// so, as shuffle did before it was a mode.
class ShuffleButton extends StatefulWidget {
  const ShuffleButton({
    super.key,
    required this.controller,
    this.words = true,
    this.bare = false,
  });

  final RoomController controller;

  /// Whether the pill has its word beside the icon.
  final bool words;

  /// Only the icon, lit in the accent while on, with no pill: for the face of a player.
  final bool bare;

  @override
  State<ShuffleButton> createState() => _ShuffleButtonState();
}

class _ShuffleButtonState extends State<ShuffleButton> {
  int _turns = 0;

  void _press(bool? shuffle) {
    HapticFeedback.selectionClick();
    final c = widget.controller;
    if (shuffle != null) return unawaited(c.setShuffle(!shuffle));
    setState(() => _turns++);
    c.shuffle();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(S.upNextShuffled),
          duration: const Duration(milliseconds: 1400),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final snapshot = widget.controller.snapshot;
    final shuffle = snapshot.shuffle;
    final on = shuffle ?? false;
    // A room that only lets its owner steer: nothing to press for a guest. Without the mode, nothing to mix below two
    final enabled =
        snapshot.canControl && (shuffle != null || snapshot.upNext.length > 1);
    final color = on
        ? (widget.bare ? p.primary : p.onPrimary)
        : enabled
        ? p.textSecondary
        : p.textTertiary.withValues(alpha: 0.5);
    return _Pill(
      bare: widget.bare,
      onPressed: enabled ? () => _press(shuffle) : null,
      tooltip: shuffle == null
          ? S.shuffle
          : on
          ? S.shuffleOn
          : S.shuffleOff,
      label: S.shuffle,
      words: widget.words,
      color: color,
      on: on,
      icon: AnimatedRotation(
        turns: _turns.toDouble(),
        duration: Motion.of(context, 420),
        curve: Curves.easeOutCubic,
        child: Icon(Icons.shuffle_rounded, color: color),
      ),
    );
  }
}

/// Cycles off, repeat all, repeat this song. Lit up while repeating.
class RepeatButton extends StatelessWidget {
  const RepeatButton({
    super.key,
    required this.controller,
    this.words = true,
    this.bare = false,
  });

  final RoomController controller;

  /// Whether the pill has its word beside the icon.
  final bool words;

  /// Only the icon, lit in the accent while on, with no pill: for the face of a player.
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mode = controller.snapshot.repeat;
    final on = mode != Repeat.off;
    final color = on ? (bare ? p.primary : p.onPrimary) : p.textSecondary;
    return _Pill(
      bare: bare,
      onPressed: controller.cycleRepeat,
      tooltip: switch (mode) {
        Repeat.off => S.repeatOff,
        Repeat.all => S.repeatAll,
        Repeat.one => S.repeatOne,
      },
      label: S.repeat,
      words: words,
      color: color,
      on: on,
      icon: Icon(
        mode == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        color: color,
      ),
    );
  }
}

/// Whether what plays when the queue ends goes on by itself: this device's own choice outside a room, the room's in
/// one (only whoever controls the room can change it). Lit up while on.
class _AutoplayButton extends StatelessWidget {
  const _AutoplayButton({required this.controller, required this.words});

  final RoomController controller;

  /// Whether the pill has its word beside the icon.
  final bool words;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final snapshot = controller.snapshot;
    final alone = !snapshot.inRoom;
    final on = alone ? controller.autoplay : snapshot.roomAutoplay == true;
    final canChange = alone || snapshot.canControl;
    final color = on
        ? p.onPrimary
        : canChange
        ? p.textSecondary
        : p.textTertiary.withValues(alpha: 0.5);
    return _Pill(
      onPressed: canChange
          ? () => alone
                ? controller.setAutoplay(!on)
                : controller.setRoomAutoplay(!on)
          : null,
      tooltip: S.autoplay,
      label: S.autoplay,
      words: words,
      color: color,
      on: on,
      icon: Icon(Icons.all_inclusive_rounded, color: color),
    );
  }
}

/// A button of the strip over the queue, wide and soft like Apple Music's: filled with the theme colour while on.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.onPressed,
    required this.tooltip,
    required this.label,
    required this.words,
    required this.color,
    required this.on,
    required this.icon,
    this.bare = false,
  });

  /// Only the icon, in a square the size of a touch.
  final bool bare;
  final VoidCallback? onPressed;
  final String tooltip;

  /// What the button is, in words next to its icon: three icons side by side were guessed at. Smaller when the pill is
  /// narrow or the words long; the tooltip says what it does now.
  final String label;
  final bool words;
  final Color color;
  final bool on;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (bare) {
      return IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: icon,
        iconSize: 24,
        color: color,
        disabledColor: color,
      );
    }
    // The pill is drawn 40 high; a touch answers in the 48 round it
    return TouchBox(
      onTap: onPressed,
      child: Tooltip(
      message: tooltip,
      child: Material(
        color: on ? p.primary : p.primary.withValues(alpha: 0.12),
        // Off, an edge of the accent: the tint alone is 1.1:1 on the page in the light theme, and the pill read as nothing
        shape: StadiumBorder(
          side: on
              ? BorderSide.none
              : BorderSide(
                  color: p.primary.withValues(
                    alpha: p.brightness == Brightness.light ? 0.75 : 0.55,
                  ),
                ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          excludeFromSemantics: true,
          onTap: onPressed,
          child: SizedBox(
            height: 40,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      if (words) ...[
                        const SizedBox(width: 6),
                        Text(
                          label,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: color),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// Songs like the one playing, from its radio. They are what plays when the queue ends, and a switch turns that off:
/// this device's own choice outside a room, the room's in one (a server too old for that has nothing play by itself,
/// so they are only there to pick from).
class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  static const _shown = 15;

  Future<SongRadio>? _radio;
  String? _for;

  void _load() {
    _for = widget.current.videoId;
    _radio = AppScope.of(context).music.radio(widget.current.videoId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_radio == null) _load();
  }

  @override
  void didUpdateWidget(_Suggestions old) {
    super.didUpdateWidget(old);
    if (widget.current.videoId != _for) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final snapshot = c.snapshot;
    final p = context.palette;
    final alone = !snapshot.inRoom;
    final roomAutoplay = snapshot.roomAutoplay;
    final lined = snapshot.autoUpNext;
    // Songs the room already lined up are what plays next once the queue ends: they stand where the suggestions would
    if (lined.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(S.autoplay, icon: Icons.auto_awesome_rounded),
          QueuedAutoplay(controller: c, entries: lined),
        ],
      );
    }
    return FutureBuilder<SongRadio>(
      key: ValueKey(_for),
      future: _radio,
      builder: (context, async) {
        final Widget body;
        if (async.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (async.hasError) {
          body = SizedBox(
            height: 200,
            child: PlayerMessage(
              icon: Icons.cloud_off_rounded,
              text: S.musicFailed,
              action: S.tryAgain,
              onAction: () => setState(_load),
            ),
          );
        } else {
          final radio = async.data!.tracks
              .where((t) => t.videoId != widget.current.videoId)
              .toList();
          final songs = snapshot.fresh(radio, queuedOnly: false).take(_shown).toList();
          body = TrackSection(title: '', tracks: songs);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (alone || roomAutoplay != null)
              // The heading and what it is, in one line: the explanation at length is in Settings
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: S.autoplay,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      TextSpan(
                        text:
                            ' · ${alone ? S.autoplayShort : S.roomAutoplayShort}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: p.textSecondary),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              SectionHeading(S.suggested),
            body,
          ],
        );
      },
    );
  }
}
