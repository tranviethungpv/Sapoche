import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../player_sheet.dart';
import 'artwork.dart';
import 'video_frame_stub.dart' if (dart.library.js_interop) 'video_frame_web.dart';

/// Where and how the frame of YouTube is shown right now.
typedef _Shape = ({Size size, double radius, bool crop});

/// The frame of the YouTube player is one piece of the page that cannot be moved from one place of the tree to another
/// (it would load again), so it floats over the screen and follows a [VideoFrameSlot], a place the layout has kept for
/// it: the picture in the full player, or the small cover of the mini player while the player is closed. Everything
/// the app draws as a route or a dialog is above it, as it should be.
class VideoFrame {
  const VideoFrame._();

  static final _page = LayerLink();
  static final _mini = LayerLink();
  static const _gone = (size: Size(1, 1), radius: 0.0, crop: false);
  static final _pageShape = ValueNotifier<_Shape>(_gone);
  static final _miniShape = ValueNotifier<_Shape>(_gone);
  static var _pageSlots = 0;
  static var _miniSlots = 0;
}

/// A place for the frame: the child is what shows until the frame is there, and the frame takes the size of the child.
/// Only a browser has a frame; leave this out elsewhere.
class VideoFrameSlot extends StatefulWidget {
  const VideoFrameSlot({
    super.key,
    required this.child,
    this.mini = false,
    this.radius = 0,
    this.crop = false,
  });

  final Widget child;

  /// A place of the mini player (or the player bar), used while the full player is closed; otherwise one of the
  /// full player.
  final bool mini;
  final double radius;

  /// The picture fills the place and loses its sides, for a small round place; else all of it shows, as it is.
  final bool crop;

  @override
  State<VideoFrameSlot> createState() => _VideoFrameSlotState();
}

class _VideoFrameSlotState extends State<VideoFrameSlot> {
  ValueNotifier<_Shape> get _shape => widget.mini ? VideoFrame._miniShape : VideoFrame._pageShape;

  @override
  void initState() {
    super.initState();
    widget.mini ? VideoFrame._miniSlots++ : VideoFrame._pageSlots++;
  }

  @override
  void dispose() {
    final mini = widget.mini;
    final shape = _shape;
    mini ? VideoFrame._miniSlots-- : VideoFrame._pageSlots--;
    // Another place may take over in this very frame (a panel of the player instead of the picture)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if ((mini ? VideoFrame._miniSlots : VideoFrame._pageSlots) == 0) shape.value = VideoFrame._gone;
    });
    super.dispose();
  }

  void _report() {
    if (!mounted) return;
    final size = context.size;
    if (size == null || size.isEmpty) return;
    _shape.value = (size: size, radius: widget.radius, crop: widget.crop);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return CompositedTransformTarget(
      link: widget.mini ? VideoFrame._mini : VideoFrame._page,
      child: widget.child,
    );
  }
}

/// The frame itself, over the home screen and under whatever is pushed on top of it. Only for a browser.
class VideoFrameHost extends StatefulWidget {
  const VideoFrameHost({super.key, required this.sheet});

  final PlayerSheetController sheet;

  @override
  State<VideoFrameHost> createState() => _VideoFrameHostState();
}

class _VideoFrameHostState extends State<VideoFrameHost> {
  final _frame = buildVideoFrame();

  @override
  void initState() {
    super.initState();
    assert(kIsWeb, 'there is a frame of YouTube only in a browser');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.sheet.position, VideoFrame._pageShape, VideoFrame._miniShape]),
    builder: (context, _) {
      // The picture goes with the player's page as soon as it starts to open, and is back in the mini player when closed
      final mini = widget.sheet.position.value == 0;
      final shape = (mini ? VideoFrame._miniShape : VideoFrame._pageShape).value;
      final gone = shape.size == const Size(1, 1);
      lookOfVideoFrame(hidden: gone, crop: shape.crop);
      return Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: mini ? VideoFrame._mini : VideoFrame._page,
          child: IgnorePointer(
            child: SizedBox.fromSize(
              size: shape.size,
              child: ClipRRect(borderRadius: BorderRadius.circular(shape.radius), child: _frame),
            ),
          ),
        ),
      );
    },
  );
}

/// The round cover of the mini player and of the player bar. In a browser that shows video the picture of the song
/// plays in it while the full player is closed.
class MiniCover extends StatelessWidget {
  const MiniCover({
    super.key,
    required this.sheet,
    required this.url,
    required this.size,
    required this.video,
  });

  final PlayerSheetController sheet;
  final String? url;
  final double size;

  /// Whether the song is shown as video.
  final bool video;

  @override
  Widget build(BuildContext context) {
    final cover = Artwork(key: sheet.miniCover, url: url, size: size, radius: size / 2);
    return kIsWeb && video ? VideoFrameSlot(mini: true, radius: size / 2, crop: true, child: cover) : cover;
  }
}
