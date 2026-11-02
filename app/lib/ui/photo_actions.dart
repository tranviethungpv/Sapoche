import 'package:flutter/material.dart';

import '../data/photo_save.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import 'scope.dart';
import 'widgets/album_image.dart';

/// Saves [slots] to the phone's gallery (to the downloads of a browser) and tells how it went in a message at the foot of
/// the screen. Pictures that cannot be had are counted as not saved.
Future<void> savePhotos(BuildContext context, RoomController controller, List<AlbumSlot> slots) async {
  final save = AppScope.of(context).photoSaver;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final room = controller.snapshot.room ?? '';
  final stamp = DateTime.now().millisecondsSinceEpoch;
  var saved = 0;
  var denied = false;
  for (var i = 0; i < slots.length && !denied; i++) {
    final bytes = await slots[i].load(controller.media, room);
    if (bytes == null) continue;
    final result = await save(bytes, 'sapoche_${stamp}_${i + 1}', slots[i].mime);
    if (result == PhotoSaveResult.saved) saved++;
    denied = result == PhotoSaveResult.denied;
  }
  final text = denied
      ? S.photoSaveDenied
      : saved == 0
      ? S.photoSaveFailed
      : S.photosSaved(saved);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
