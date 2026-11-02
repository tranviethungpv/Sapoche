import 'package:flutter/material.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'photo_actions.dart';
import 'photo_viewer.dart';
import 'widgets/album_image.dart';
import 'widgets/grow_route.dart';
import 'widgets/photo_stack.dart' show screenRectOf;

/// The pictures of one message of the chat, all together: opens out of the stack ([from] is where it was on screen).
/// [sender] is null for this device's own messages.
Future<void> showAlbumPage(
  BuildContext context, {
  required RoomController controller,
  required List<AlbumSlot> slots,
  required String when,
  required Rect? from,
  String? sender,
  String? caption,
}) => Navigator.of(context, rootNavigator: true).push(
  growRoute<void>(
    from: from,
    builder: (_) => AlbumPage(controller: controller, slots: slots, sender: sender, when: when, caption: caption),
  ),
);

class AlbumPage extends StatelessWidget {
  const AlbumPage({
    super.key,
    required this.controller,
    required this.slots,
    required this.when,
    this.sender,
    this.caption,
  });

  final RoomController controller;
  final List<AlbumSlot> slots;
  final String when;

  /// Who sent them; null for this device.
  final String? sender;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final name = sender == null ? S.you : (sender!.isEmpty ? S.someone : sender!);
    final room = controller.snapshot.room ?? '';
    return Scaffold(
      key: const ValueKey('album-page'),
      backgroundColor: p.base,
      appBar: AppBar(
        backgroundColor: p.base,
        title: Text('$name · ${S.photoCount(slots.length)} · $when', style: theme.titleMedium),
        actions: [
          IconButton(
            key: const ValueKey('album-save-all'),
            tooltip: S.photoSaveAll,
            onPressed: () => savePhotos(context, controller, slots),
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (caption != null && caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(caption!, key: const ValueKey('album-caption'), style: theme.bodyMedium),
              ),
            ),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: slots.length,
              itemBuilder: (context, i) => _Cell(
                controller: controller,
                slot: slots[i],
                room: room,
                onTap: (from) => showPhotoViewer(context, controller: controller, slots: slots, initial: i, from: from),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.controller, required this.slot, required this.room, required this.onTap});

  final RoomController controller;
  final AlbumSlot slot;
  final String room;
  final ValueChanged<Rect?> onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('album-cell-${slot.id}'),
      onTap: () => onTap(screenRectOf(context)),
      child: AlbumImage(slot: slot, media: controller.media, room: room, cacheWidth: 360),
    );
  }
}
