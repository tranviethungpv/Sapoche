import 'package:flutter/material.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import 'photo_actions.dart';
import 'widgets/album_image.dart';
import 'widgets/grow_route.dart';

/// The pictures of a message full screen, to swipe between, pinch and double-tap to zoom, and pull down to leave. It
/// opens at [initial], growing out of [from] when that is known.
Future<void> showPhotoViewer(
  BuildContext context, {
  required RoomController controller,
  required List<AlbumSlot> slots,
  required Rect? from,
  int initial = 0,
}) => Navigator.of(context, rootNavigator: true).push(
  growRoute<void>(
    from: from,
    builder: (_) => PhotoViewer(controller: controller, slots: slots, initial: initial),
  ),
);

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.controller, required this.slots, this.initial = 0});

  final RoomController controller;
  final List<AlbumSlot> slots;
  final int initial;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  /// How far down the picture is pulled before letting go leaves, in px; a quick flick leaves from less.
  static const _leaveAt = 120.0;
  static const _flick = 800.0;

  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _zoomed = false;
  double _pull = 0;
  bool _pulling = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _letGo(DragEndDetails end) {
    final speed = end.velocity.pixelsPerSecond.dy;
    if (_pull.abs() > _leaveAt || speed.abs() > _flick) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _pull = 0;
      _pulling = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final slots = widget.slots;
    final room = widget.controller.snapshot.room ?? '';
    final bars = (1 - _pull.abs() / 200).clamp(0.0, 1.0);
    return Theme(
      data: Theme.of(context).copyWith(iconTheme: const IconThemeData(color: Colors.white)),
      child: Scaffold(
        key: const ValueKey('photo-viewer'),
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // A picture that is zoomed is dragged about instead
              onVerticalDragUpdate: _zoomed
                  ? null
                  : (move) => setState(() {
                      _pulling = true;
                      _pull += move.delta.dy;
                    }),
              onVerticalDragEnd: _zoomed ? null : _letGo,
              onVerticalDragCancel: () => setState(() {
                _pull = 0;
                _pulling = false;
              }),
              child: AnimatedContainer(
                duration: _pulling ? Duration.zero : const Duration(milliseconds: 180),
                transform: Matrix4.translationValues(0, _pull, 0),
                child: PageView.builder(
                  controller: _pages,
                  physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                  itemCount: slots.length,
                  onPageChanged: (i) => setState(() {
                    _index = i;
                    _zoomed = false;
                  }),
                  itemBuilder: (context, i) => _ZoomPage(
                    key: ValueKey(slots[i].id),
                    slot: slots[i],
                    controller: widget.controller,
                    room: room,
                    playing: i == _index,
                    onZoom: (zoomed) {
                      if (i == _index && zoomed != _zoomed) setState(() => _zoomed = zoomed);
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Opacity(
                opacity: bars,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('viewer-close'),
                          tooltip: S.close,
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                        Expanded(
                          child: Text(
                            slots.length > 1 ? '${_index + 1}/${slots.length}' : '',
                            key: const ValueKey('viewer-index'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('viewer-save'),
                          tooltip: S.photoSave,
                          onPressed: () => savePhotos(context, widget.controller, [slots[_index]]),
                          icon: const Icon(Icons.download_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One picture of the viewer, to pinch and double-tap. Tells [onZoom] when it is zoomed in or back.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({
    super.key,
    required this.slot,
    required this.controller,
    required this.room,
    required this.playing,
    required this.onZoom,
  });

  final AlbumSlot slot;
  final RoomController controller;
  final String room;
  final bool playing;
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> {
  static const _maxScale = 4.0;
  static const _doubleTapScale = 2.5;

  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_changed);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _changed() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    widget.onZoom(zoomed);
  }

  /// Zooms in on the spot that was touched, or back out when already zoomed in.
  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      return;
    }
    final at = _doubleTapAt;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (_doubleTapScale - 1), -at.dy * (_doubleTapScale - 1), 0, 1)
      ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (down) => _doubleTapAt = down.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: _maxScale,
        // At rest a drag belongs to the page: sideways to the next picture, down to leave
        panEnabled: _zoomed,
        child: SizedBox.expand(
          child: AlbumImage(
            slot: widget.slot,
            media: widget.controller.media,
            room: widget.room,
            fit: BoxFit.contain,
            backdrop: false,
            playing: widget.playing,
          ),
        ),
      ),
    );
  }
}
