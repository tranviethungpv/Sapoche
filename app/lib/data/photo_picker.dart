import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'room_controller.dart';

/// Lets the person pick a picture from their photos; gives back its bytes, already small, or null when they back out.
typedef PhotoPicker = Future<Uint8List?> Function();

/// The side of an avatar in pixels: the biggest place it is drawn is 96 dp across, about 290 px on a 3x screen.
const _avatarSide = 256;

/// JPEG qualities tried from the best down, until the picture is small enough to be sent to the room.
const _qualities = [90, 82, 74, 66, 58, 50, 42];

/// The system's own photo picker: it needs no permission. The platform scales the picture down to 1024 px first, so a
/// camera photo does not have to be decoded at full size; [squareAvatar] does the rest.
Future<Uint8List?> pickPhoto() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1024,
    maxHeight: 1024,
  );
  if (file == null) return null;
  return compute(squareAvatar, await file.readAsBytes());
}

/// The middle square of [source] as a 256 px JPEG, at the best quality that still fits what the room accepts (about
/// 18 KB); a picture smaller than that is not scaled up. Null when [source] is not a picture.
Uint8List? squareAvatar(Uint8List source) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } catch (_) {
    // The decoders throw all sorts of errors on bytes that are not a picture
    return null;
  }
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final side = min(upright.width, upright.height);
  final square = img.copyCrop(
    upright,
    x: (upright.width - side) ~/ 2,
    y: (upright.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final scaled = side > _avatarSide
      ? img.copyResize(
          square,
          width: _avatarSide,
          height: _avatarSide,
          interpolation: img.Interpolation.average,
        )
      : square;
  final limit = RoomController.maxAvatarChars ~/ 4 * 3;
  late Uint8List jpeg;
  for (final quality in _qualities) {
    jpeg = img.encodeJpg(scaled, quality: quality);
    if (jpeg.length <= limit) break;
  }
  return jpeg;
}
