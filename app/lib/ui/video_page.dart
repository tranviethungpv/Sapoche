import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../data/chat_extra.dart';
import '../data/photo_save.dart';
import '../data/room_controller.dart';
import '../data/video_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/album_image.dart';
import 'widgets/grow_route.dart';

/// Plays the video of an album message full screen, growing out of [from] when that is known.
Future<void> showVideoPage(
  BuildContext context, {
  required RoomController controller,
  required AlbumExtra album,
  required Rect? from,
}) => Navigator.of(context, rootNavigator: true).push(
  growRoute<void>(
    from: from,
    builder: (_) => VideoPage(controller: controller, album: album),
  ),
);

/// Saves the video of [album] to the gallery (the downloads of a browser) and says how it went.
Future<void> saveVideo(BuildContext context, RoomController controller, AlbumExtra album) async {
  final save = AppScope.of(context).photoSaver;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final bytes = await controller.media.open(controller.snapshot.room ?? '', album.video);
  final result = bytes == null
      ? PhotoSaveResult.failed
      : await save(bytes, 'sapoche_${DateTime.now().millisecondsSinceEpoch}', album.video.mime);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          PhotoSaveResult.saved => S.videoSaved,
          PhotoSaveResult.denied => S.photoSaveDenied,
          PhotoSaveResult.failed => S.photoSaveFailed,
        }),
      ),
    );
}

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.controller, required this.album});

  final RoomController controller;
  final AlbumExtra album;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoPlayerController? _player;
  void Function()? _release;
  bool _failed = false;

  AlbumItem get _video => widget.album.video;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final source = await widget.controller.media.videoSource(widget.controller.snapshot.room ?? '', _video);
    if (!mounted) return;
    if (source == null) return setState(() => _failed = true);
    ({VideoPlayerController controller, void Function() release}) made;
    try {
      made = videoControllerFor(source);
    } on Object {
      return setState(() => _failed = true);
    }
    _release = made.release;
    try {
      await made.controller.initialize();
    } on Object {
      made.controller.dispose().ignore();
      made.release();
      _release = null;
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      made.controller.dispose().ignore();
      made.release();
      return;
    }
    setState(() => _player = made.controller);
    made.controller.play().ignore();
  }

  @override
  void dispose() {
    _player?.dispose().ignore();
    _release?.call();
    super.dispose();
  }

  void _toggle() {
    final player = _player;
    if (player == null) return;
    player.value.isPlaying ? player.pause() : player.play();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final poster = AlbumSlot.item(widget.album.poster);
    final room = widget.controller.snapshot.room ?? '';
    return Theme(
      data: Theme.of(context).copyWith(iconTheme: const IconThemeData(color: Colors.white)),
      child: Scaffold(
        key: const ValueKey('video-page'),
        backgroundColor: Colors.black,
        // A column, not layers: the bar under the picture never covers any of it, and the picture takes what is left
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const ValueKey('video-close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: S.close,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: player == null
                    // The poster until the video is ready
                    ? AspectRatio(
                        aspectRatio: poster.aspect,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AlbumImage(slot: poster, media: widget.controller.media, room: room, cacheWidth: 720),
                            Center(
                              child: _failed
                                  ? Text(
                                      S.videoCannotPlay,
                                      key: const ValueKey('video-failed'),
                                      style: const TextStyle(color: Colors.white),
                                    )
                                  : const CircularProgressIndicator(
                                      key: ValueKey('video-loading'),
                                      color: Colors.white,
                                    ),
                            ),
                          ],
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('video-surface'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggle,
                        child: AspectRatio(aspectRatio: player.value.aspectRatio, child: VideoPlayer(player)),
                      ),
              ),
            ),
            // The room of the bar is kept before the video is ready, so that the picture does not jump
            SafeArea(
              top: false,
              child: SizedBox(
                height: 56,
                child: player == null
                    ? null
                    : _Controls(player: player, onSave: () => saveVideo(context, widget.controller, widget.album)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Play or pause, where it has got to (touch or drag to move it), how long it is, and the way to keep it.
class _Controls extends StatelessWidget {
  const _Controls({required this.player, required this.onSave});

  final VideoPlayerController player;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds;
        final at = value.position.inMilliseconds.clamp(0, total > 0 ? total : 0);
        final done = total > 0 && at >= total;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('video-play'),
                onPressed: () {
                  if (done) player.seekTo(Duration.zero);
                  value.isPlaying ? player.pause() : player.play();
                },
                icon: Icon(value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
              ),
              Text(formatDuration(at), style: const TextStyle(color: Colors.white)),
              Expanded(
                child: Slider(
                  key: const ValueKey('video-seek'),
                  value: at.toDouble(),
                  max: total > 0 ? total.toDouble() : 1,
                  activeColor: p.primary,
                  inactiveColor: Colors.white24,
                  onChanged: total > 0 ? (v) => player.seekTo(Duration(milliseconds: v.round())) : null,
                ),
              ),
              Text(formatDuration(total), style: const TextStyle(color: Colors.white)),
              IconButton(
                key: const ValueKey('video-save'),
                onPressed: onSave,
                tooltip: S.videoSave,
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
        );
      },
    );
  }
}
