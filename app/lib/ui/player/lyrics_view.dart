import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../widgets/low_rate_timer.dart';
import 'player_message.dart';

/// The words of the song. With times they run along with the music like in Apple Music: the line being sung is
/// bright and stays where the eye is, and a touch on a line jumps the song there.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.controller, required this.track});

  final RoomController controller;
  final Track track;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Future<Lyrics?>? _lyrics;
  String? _for;

  void _load() {
    _for = widget.track.videoId;
    _lyrics = AppScope.of(context).music.lyrics(widget.track);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lyrics == null) _load();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (widget.track.videoId != _for) _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lyrics?>(
      key: ValueKey(_for),
      future: _lyrics,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasError) {
          return PlayerMessage(
            icon: Icons.cloud_off_rounded,
            text: S.lyricsFailed,
            action: S.tryAgain,
            onAction: () => setState(_load),
          );
        }
        final lyrics = snapshot.data;
        if (lyrics == null) {
          return const PlayerMessage(
            icon: Icons.lyrics_outlined,
            text: S.noLyrics,
          );
        }
        return lyrics.synced
            ? _SyncedLyrics(controller: widget.controller, lyrics: lyrics)
            : _PlainLyrics(text: lyrics.plain ?? '');
      },
    );
  }
}

class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 40),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w600, height: 1.5),
      ),
    );
  }
}

class _SyncedLyrics extends StatefulWidget {
  const _SyncedLyrics({required this.controller, required this.lyrics});

  final RoomController controller;
  final Lyrics lyrics;

  @override
  State<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<_SyncedLyrics> {
  /// A line lights up a little before it is sung, as the eye needs the time to read it.
  static const _leadMs = 250;

  /// After the person scrolls by hand the view leaves them alone for this long.
  static const _handOffMs = 4000;

  late final LowRateTimer _ticker = LowRateTimer(
    const Duration(milliseconds: 200),
    _update,
  );
  late final _keys = List.generate(
    widget.lyrics.lines.length,
    (_) => GlobalKey(),
  );
  int? _active;
  DateTime _scrolledAt = DateTime.fromMillisecondsSinceEpoch(0);

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.player.addListener(_sync);
    _c.addListener(_sync);
    _sync();
    // The first look puts the line being sung in place at once
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
  }

  @override
  void dispose() {
    _c.player.removeListener(_sync);
    _c.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  void _sync() {
    _ticker.run(_c.player.value.playing);
    _update();
  }

  void _update() {
    if (!mounted) return;
    final line = widget.lyrics.lineAt(_c.positionMs() + _leadMs);
    if (line == _active) return;
    setState(() => _active = line);
    _follow();
  }

  void _follow({bool jump = false}) {
    final line = _active;
    if (line == null || !mounted) return;
    if (DateTime.now().difference(_scrolledAt).inMilliseconds < _handOffMs) {
      return;
    }
    final context = _keys[line].currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.3,
      duration: jump ? Duration.zero : const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.headlineSmall
        ?.copyWith(fontWeight: FontWeight.w800, height: 1.25);
    final lines = widget.lyrics.lines;
    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        if (n.direction != ScrollDirection.idle) _scrolledAt = DateTime.now();
        return false;
      },
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          4,
          24,
          4,
          MediaQuery.sizeOf(context).height * 0.4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++)
              GestureDetector(
                key: _keys[i],
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // Seeking is a deliberate act: the view follows it at once
                  _scrolledAt = DateTime.fromMillisecondsSinceEpoch(0);
                  _c.seek(lines[i].ms);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: AnimatedOpacity(
                    opacity: i == _active ? 1 : 0.38,
                    duration: const Duration(milliseconds: 300),
                    child: lines[i].text.isEmpty
                        ? Icon(Icons.more_horiz_rounded, color: p.text)
                        : Text(lines[i].text, style: style),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
