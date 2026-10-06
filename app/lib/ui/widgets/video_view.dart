import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../theme/theme.dart';
import 'artwork.dart';

/// The picture of the current song. The native player draws it into a texture that this shows.
/// While it is on screen the player is told so, and told again when it is not (another app on top,
/// screen off), so a picture nobody sees is not downloaded or decoded.
class VideoView extends StatefulWidget {
  const VideoView({
    super.key,
    required this.controller,
    required this.cover,
    this.fit,
    this.overlay,
  });

  final RoomController controller;

  /// Shown until the first frame arrives.
  final QueueEntry cover;

  /// Null: a rounded frame of the picture's own shape, as large as the place allows, whether the picture is wide,
  /// upright or square. Otherwise the picture takes the whole place this way, on black (full screen, small window).
  final BoxFit? fit;

  /// Drawn over the picture, inside its frame: the controls.
  final Widget? overlay;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> with WidgetsBindingObserver {
  int? _texture;

  RoomController get _room => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _room.setVideoSeen(this, _seen(WidgetsBinding.instance.lifecycleState));
    _room.videoSurface().then((id) {
      if (mounted && id != null) setState(() => _texture = id);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _room.setVideoSeen(this, false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _room.setVideoSeen(this, _seen(state));
  }

  /// Only an app that went to the background hides the picture. A control centre, a call coming in or the app
  /// switcher make it inactive for a moment, and taking the picture away then would cost a gap in the sound.
  static bool _seen(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: _room.player,
      builder: (context, _) {
        final size = _room.player.value;
        final ready = size.videoWidth > 0 && size.videoHeight > 0;
        // A song with no picture to be had shows its cover, without a spinner that would turn for ever
        final waiting = !ready && !size.noPicture;
        final fit = widget.fit;
        final picture = Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: fit == null ? p.primaryContainer : Colors.black),
            // Until the picture starts, the cover with a spinner on it
            if (!ready)
              LayoutBuilder(
                builder: (context, box) => Artwork(
                  url: widget.cover.thumb,
                  size: box.maxWidth,
                  radius: 0,
                  sharp: true,
                ),
              ),
            if (waiting)
              const Center(
                child: SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            if (_texture != null && ready) Texture(textureId: _texture!),
          ],
        );
        if (fit != null) {
          // The picture at its own size, scaled to the place: with bars where the shapes differ, or cropped
          final width = ready ? size.videoWidth.toDouble() : 1600.0;
          final height = ready ? size.videoHeight.toDouble() : 900.0;
          return ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: FittedBox(
                    fit: fit,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: picture,
                    ),
                  ),
                ),
                ?widget.overlay,
              ],
            ),
          );
        }
        return Center(
          child: AspectRatio(
            aspectRatio: ready ? size.videoWidth / size.videoHeight : 16 / 9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [picture, ?widget.overlay],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
