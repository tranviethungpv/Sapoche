import 'package:flutter/material.dart';

import '../data/chat_media.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';

/// What the person made of the photos they picked: which of them to send, in what order, and the words under them.
class PhotoDraft {
  const PhotoDraft(this.photos, this.caption);

  final List<PreparedPhoto> photos;
  final String caption;
}

/// Shows the picked [photos] before they are sent: each can be taken out with its cross, the order is changed by holding
/// one and dragging it, and a caption can be written. Null when the person cancels.
Future<PhotoDraft?> showPhotoPreview(
  BuildContext context,
  List<PreparedPhoto> photos,
) => showModalBottomSheet<PhotoDraft>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (_) => _PhotoPreview(photos: photos),
);

class _PhotoPreview extends StatefulWidget {
  const _PhotoPreview({required this.photos});

  final List<PreparedPhoto> photos;

  @override
  State<_PhotoPreview> createState() => _PhotoPreviewState();
}

class _PhotoPreviewState extends State<_PhotoPreview> {
  static const _side = 104.0;

  /// The words go in the message after "📷 7 photos ", which has to fit with them in what the room accepts.
  static const _captionChars = RoomController.maxChatChars - 24;

  late final List<PreparedPhoto> _photos = [...widget.photos];
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  void _remove(PreparedPhoto photo) {
    setState(() => _photos.remove(photo));
    // Nothing left to send
    if (_photos.isEmpty) Navigator.of(context).pop();
  }

  void _move(int from, int to) => setState(() {
    final photo = _photos.removeAt(from);
    _photos.insert(to, photo);
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.photoCount(_photos.length),
                  key: const ValueKey('photo-preview-count'),
                  style: theme.titleMedium,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: _side + 8,
                  child: ReorderableListView.builder(
                    key: const ValueKey('photo-preview-list'),
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    itemCount: _photos.length,
                    onReorderItem: _move,
                    itemBuilder: (context, i) {
                      final photo = _photos[i];
                      return ReorderableDelayedDragStartListener(
                        key: ObjectKey(photo),
                        index: i,
                        child: _Thumb(
                          photo: photo,
                          index: i,
                          side: _side,
                          onRemove: () => _remove(photo),
                        ),
                      );
                    },
                  ),
                ),
                if (_photos.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      S.photoReorderHint,
                      style: theme.bodySmall?.copyWith(color: p.textTertiary),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('photo-caption'),
                  controller: _caption,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: _captionChars,
                  buildCounter: (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: S.photoCaptionHint,
                    isDense: true,
                    filled: true,
                    fillColor: p.primary.withValues(alpha: 0.10),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey('photo-preview-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(S.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const ValueKey('photo-preview-send'),
                      onPressed: () => Navigator.of(context)
                          .pop(PhotoDraft([..._photos], _caption.text.trim())),
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: Text(S.chatSend),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
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
  });

  final PreparedPhoto photo;
  final int index;
  final double side;
  final VoidCallback onRemove;

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
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ),
            ),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      'GIF',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
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
                  key: ValueKey('photo-remove-$index'),
                  onTap: onRemove,
                  radius: 18,
                  child: Tooltip(
                    message: S.photoRemove,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
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
