import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../strings.dart';

/// Shows a picture of someone over the whole screen, to pinch, drag and double-tap. A touch outside it, or the cross,
/// puts it away.
Future<void> showAvatarZoom(
  BuildContext context, {
  required String name,
  required Uint8List image,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    barrierDismissible: true,
    barrierLabel: S.close,
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (_, _, _) => _AvatarZoom(name: name, image: image),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class _AvatarZoom extends StatefulWidget {
  const _AvatarZoom({required this.name, required this.image});

  final String name;
  final Uint8List image;

  @override
  State<_AvatarZoom> createState() => _AvatarZoomState();
}

class _AvatarZoomState extends State<_AvatarZoom> {
  /// The pictures kept by the room are small, so a larger zoom only shows the pixels.
  static const _maxScale = 4.0;

  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Zooms in on the spot that was touched, or back out when already zoomed in.
  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    final at = _doubleTapAt;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The space around the picture
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('avatar-zoom-backdrop'),
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        Center(
          child: LayoutBuilder(
            builder: (context, box) {
              // As large as the screen allows, with room above and below to touch for putting it away
              final side = min(box.maxWidth, box.maxHeight * 0.8);
              return GestureDetector(
                onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  key: const ValueKey('avatar-zoom'),
                  transformationController: _transform,
                  maxScale: _maxScale,
                  child: Semantics(
                    image: true,
                    label: widget.name,
                    child: SizedBox.square(
                      dimension: side,
                      child: Image.memory(
                        widget.image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: IconButton(
              key: const ValueKey('avatar-zoom-close'),
              tooltip: S.close,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                widget.name,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
