import 'package:flutter/material.dart';

import '../../data/chat_extra.dart';
import '../../data/chat_media.dart';
import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../theme/theme.dart';
import '../album_page.dart';
import '../photo_viewer.dart';
import 'album_image.dart';
import 'photo_stack.dart';

/// The pictures of a message of the chat: one picture alone, or a stack of them that opens into the album. A message that
/// is still on its way (or failed) shows the previews kept for it, with how far they have gone up.
class AlbumBubble extends StatelessWidget {
  const AlbumBubble({
    super.key,
    required this.controller,
    required this.message,
    required this.when,
    this.album,
    this.upload,
  });

  /// A message newer than this has just arrived, so its stack fans out.
  static const freshFor = Duration(seconds: 8);

  final RoomController controller;
  final ChatMessage message;

  /// The time of the message as the page of the album writes it.
  final String when;

  /// What the room has of the message; null while it is on its way.
  final AlbumExtra? album;

  /// The pictures going up for a message that the room has not confirmed.
  final AlbumUpload? upload;

  List<AlbumSlot> get _slots {
    final album = this.album;
    if (album != null) return [for (final item in album.items) AlbumSlot.item(item)];
    final photos = upload?.photos ?? const <PreparedPhoto>[];
    return [for (var i = 0; i < photos.length; i++) AlbumSlot.photo(photos[i], i)];
  }

  bool get _fresh => DateTime.now().millisecondsSinceEpoch - message.at < freshFor.inMilliseconds;

  void _open(BuildContext context, List<AlbumSlot> slots, Rect? from) {
    if (message.delivery == ChatDelivery.failed) {
      controller.resendChat(message);
      return;
    }
    // Pictures on their way are not in the room yet
    if (album == null) return;
    final sender = message.by == controller.snapshot.you ? null : message.name;
    if (slots.length == 1) {
      showPhotoViewer(context, controller: controller, slots: slots, from: from);
    } else {
      showAlbumPage(
        context,
        controller: controller,
        slots: slots,
        sender: sender,
        when: when,
        caption: album?.caption,
        from: from,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = _slots;
    if (slots.isEmpty) return const SizedBox.shrink();
    final room = controller.snapshot.room ?? '';
    final key = ValueKey(message.cid ?? message.id);
    final overlay = _Overlay(upload: upload, failed: message.delivery == ChatDelivery.failed);
    return slots.length == 1
        ? SinglePhoto(
            key: key,
            slot: slots.first,
            media: controller.media,
            room: room,
            onTap: (from) => _open(context, slots, from),
            overlay: overlay,
          )
        : PhotoStack(
            key: key,
            slots: slots,
            media: controller.media,
            room: room,
            fresh: _fresh,
            onTap: (from) => _open(context, slots, from),
            overlay: overlay,
          );
  }
}

/// Over the top picture of a message on its way: a ring with how many pictures are up, or a red mark where it failed.
class _Overlay extends StatelessWidget {
  const _Overlay({required this.upload, required this.failed});

  final AlbumUpload? upload;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final upload = this.upload;
    if (upload == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: upload,
      builder: (context, _) {
        final broke = failed || upload.states.contains(FileState.failed);
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black.withValues(alpha: broke ? 0.45 : 0.3)),
            if (broke)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  key: const ValueKey('photo-failed'),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: context.palette.error, shape: BoxShape.circle),
                  child: const Icon(Icons.priority_high_rounded, size: 18, color: Colors.white),
                ),
              )
            else
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: CircularProgressIndicator(
                        key: const ValueKey('photo-progress'),
                        value: upload.done == 0 ? null : upload.done / upload.total,
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                    if (upload.total > 1)
                      Text(
                        '${upload.done}/${upload.total}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
