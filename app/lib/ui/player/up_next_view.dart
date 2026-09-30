import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../widgets/delete_background.dart';
import '../widgets/track_tile.dart';
import 'player_message.dart';
import 'track_section.dart';

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
        return CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SectionHeading(
                S.upNext,
                action: upNext.length > 1
                    ? IconButton(
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          controller.shuffle();
                        },
                        tooltip: S.shuffle,
                        icon: Icon(
                          Icons.shuffle_rounded,
                          color: context.palette.primary,
                        ),
                      )
                    : null,
              ),
            ),
            if (upNext.isEmpty)
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
            SliverReorderableList(
              itemCount: upNext.length,
              onReorderItem: (from, to) =>
                  controller.move(upNext[from], snapshot.myIndex + 1 + to),
              proxyDecorator: (child, _, animation) => Material(
                color: Colors.transparent,
                elevation: 0,
                child: ScaleTransition(
                  scale: Tween(begin: 1.0, end: 1.02).animate(animation),
                  child: child,
                ),
              ),
              itemBuilder: (context, i) {
                final entry = upNext[i];
                return Dismissible(
                  key: ValueKey(entry.id),
                  direction: DismissDirection.endToStart,
                  background: const DeleteBackground(),
                  onDismissed: (_) {
                    HapticFeedback.lightImpact();
                    controller.remove(entry);
                  },
                  child: ReorderableDelayedDragStartListener(
                    index: i,
                    child: TrackTile(
                      track: entry,
                      onTap: () => controller.jump(entry),
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
      },
    );
  }
}

/// Songs like the one playing, from its radio. Outside a room they are what plays when the queue ends, and a
/// switch turns that off; in a room nothing plays by itself, so they are only there to pick from.
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
          final songs = snapshot.fresh(radio).take(_shown).toList();
          body = TrackSection(title: '', tracks: songs);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeading(
              alone ? S.autoplay : S.suggested,
              action: alone
                  ? Switch(value: c.autoplay, onChanged: c.setAutoplay)
                  : null,
            ),
            if (alone)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  S.autoplayNote,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: p.textSecondary),
                ),
              ),
            body,
          ],
        );
      },
    );
  }
}
