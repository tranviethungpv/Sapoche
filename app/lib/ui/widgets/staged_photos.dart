import 'package:flutter/material.dart';

import '../../data/chat_media.dart';
import '../../format.dart';
import '../../strings.dart';
import '../../theme/theme.dart';

/// The photos waiting to be sent, in a row above the field: each can be taken out with its cross, and the order is changed
/// by holding one and dragging it. What is written in the field goes with them as their caption.
class StagedPhotos extends StatelessWidget {
  const StagedPhotos({
    super.key,
    required this.photos,
    required this.onRemove,
    required this.onMove,
    this.video,
    this.onRemoveVideo,
    this.onFlip,
    this.onFlipVideo,
  });

  final List<PreparedPhoto> photos;
  final ValueChanged<PreparedPhoto> onRemove;
  final void Function(int from, int to) onMove;

  /// A video waits instead of photos: the video and its poster, in this order.
  final List<PreparedPhoto>? video;
  final VoidCallback? onRemoveVideo;

  /// Turn a photo, or the video, left to right (a selfie is saved the other way round from its preview); null where it cannot.
  final ValueChanged<PreparedPhoto>? onFlip;
  final VoidCallback? onFlipVideo;

  static const _side = 88.0;

  @override
  Widget build(BuildContext context) {
    final video = this.video;
    if (video != null) {
      return SizedBox(
        key: const ValueKey('staged-photos'),
        height: _side + 12,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _Thumb(
                photo: video.last,
                index: 0,
                side: _side,
                onRemove: onRemoveVideo ?? () {},
                removeKey: const ValueKey('video-remove'),
                onFlip: onFlipVideo,
                flipKey: const ValueKey('video-flip'),
                badge: const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${formatDuration(video.first.durMs)} · ${(video.first.bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB',
                key: const ValueKey('staged-video-info'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('staged-photos'),
      height: _side + 12,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        buildDefaultDragHandles: false,
        itemCount: photos.length,
        onReorderItem: onMove,
        itemBuilder: (context, i) {
          final photo = photos[i];
          return ReorderableDelayedDragStartListener(
            key: ObjectKey(photo),
            index: i,
            child: _Thumb(
              photo: photo,
              index: i,
              side: _side,
              onRemove: () => onRemove(photo),
              // A moving picture cannot be turned
              onFlip: onFlip == null || photo.animated ? null : () => onFlip!(photo),
            ),
          );
        },
      ),
    );
  }
}

/// One picked photo, square, with the cross that takes it out.
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.photo,
    required this.index,
    required this.side,
    required this.onRemove,
    this.removeKey,
    this.badge,
    this.onFlip,
    this.flipKey,
  });

  final PreparedPhoto photo;
  final int index;
  final double side;
  final VoidCallback onRemove;

  /// The key of the cross, where it is not the one of a photo.
  final Key? removeKey;

  /// Drawn over the picture (the play mark of a video).
  final Widget? badge;

  /// Turns the picture left to right; no button where it is null.
  final VoidCallback? onFlip;
  final Key? flipKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 8),
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  photo.bytes,
                  fit: BoxFit.cover,
                  cacheWidth: 320,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: p.surface,
                    child: Icon(Icons.broken_image_outlined, color: p.textTertiary),
                  ),
                ),
              ),
            ),
            ?badge,
            if (photo.animated)
              Positioned(
                left: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      'GIF',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            // The whole foot of the picture is the button: a place the thumb finds without aiming
            if (onFlip != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 34,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    child: InkWell(
                      key: flipKey ?? ValueKey('photo-flip-$index'),
                      onTap: onFlip,
                      child: Tooltip(
                        message: S.photoFlip,
                        child: const Center(child: Icon(Icons.flip_rounded, size: 20, color: Colors.white)),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: -6,
              top: -8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.7),
                shape: const CircleBorder(),
                child: InkResponse(
                  key: removeKey ?? ValueKey('photo-remove-$index'),
                  onTap: onRemove,
                  radius: 18,
                  child: Tooltip(
                    message: S.photoRemove,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
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
