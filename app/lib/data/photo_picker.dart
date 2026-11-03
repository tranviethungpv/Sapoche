import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'chat_extra.dart';
import 'chat_media.dart';
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

/// Lets the person pick a photo to put behind the chat, whole and upright, for them to place in the frame: no more
/// than [wallpaperPickSide] px on its longest side. Null when they back out or the file is no picture.
typedef WallpaperPicker = Future<Uint8List?> Function();

/// The longest side of the photo handed to the person to place: enough to zoom in a few times on a phone screen.
const wallpaperPickSide = 1600;

Future<Uint8List?> pickWallpaper() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: wallpaperPickSide.toDouble(),
    maxHeight: wallpaperPickSide.toDouble(),
  );
  if (file == null) return null;
  return compute(uprightPhoto, await file.readAsBytes());
}

/// [source] turned upright as a JPEG with nothing of its orientation left in it, so that what is shown and what is cut
/// out of it are the same picture; shrunk to [wallpaperPickSide] if bigger. Null when [source] is not a picture.
Uint8List? uprightPhoto(Uint8List source) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  var upright = img.bakeOrientation(decoded);
  if (max(upright.width, upright.height) > wallpaperPickSide) {
    upright = upright.width >= upright.height
        ? img.copyResize(upright, width: wallpaperPickSide)
        : img.copyResize(upright, height: wallpaperPickSide);
  }
  return img.encodeJpg(upright, quality: 88);
}

/// The longest base64 text of the picture behind the chat that the room accepts.
const maxWallpaperChars = 90000;

/// The part of [photo] inside the rectangle given as fractions of its width and height, as a JPEG [side] px wide with
/// the height of the frame, small enough to be sent to the room (about 67 KB): the quality goes down, and then the size,
/// until it fits. Null when [photo] is not a picture.
Uint8List? cutWallpaper(
  Uint8List photo, {
  required double left,
  required double top,
  required double width,
  required double height,
  int side = 540,
}) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(photo);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  final w = decoded.width, h = decoded.height;
  final x = (left * w).round().clamp(0, w - 1);
  final y = (top * h).round().clamp(0, h - 1);
  final cut = img.copyCrop(
    decoded,
    x: x,
    y: y,
    width: (width * w).round().clamp(1, w - x),
    height: (height * h).round().clamp(1, h - y),
  );
  final limit = maxWallpaperChars ~/ 4 * 3;
  late Uint8List jpeg;
  for (var wide = side; wide >= 270; wide = wide * 3 ~/ 4) {
    final scaled = cut.width > wide
        ? img.copyResize(
            cut,
            width: wide,
            interpolation: img.Interpolation.average,
          )
        : cut;
    for (final quality in const [82, 72, 62, 52, 42, 32]) {
      jpeg = img.encodeJpg(scaled, quality: quality);
      if (jpeg.length <= limit) return jpeg;
    }
  }
  return jpeg;
}

/// [cutWallpaper] on another isolate: cutting and compressing a photo takes a moment, and the screen should not stop.
Future<Uint8List?> cutWallpaperAway(
  Uint8List photo, {
  required double left,
  required double top,
  required double width,
  required double height,
}) => compute(
  (List<Object> a) => cutWallpaper(
    a[0] as Uint8List,
    left: a[1] as double,
    top: a[2] as double,
    width: a[3] as double,
    height: a[4] as double,
  ),
  [photo, left, top, width, height],
);

/// Where the photos for the chat come from, or the video: the library of the phone or its camera.
enum PhotoSource { gallery, camera, videoGallery, videoCamera }

/// Lets the person pick photos to send in the chat (one to [AlbumExtra.maxItems], in the order picked); empty when they
/// back out. The photos are handed over as they are: [ChatMedia.prepare] turns them upright and makes them smaller.
typedef ChatPhotoPicker = Future<List<PickedPhoto>> Function(PhotoSource source);

/// Lets the person pick a video to send in the chat ([PhotoSource.videoGallery] or [PhotoSource.videoCamera]); null when they
/// back out. The file is handed over as it is: [ChatMedia.prepareVideo] squeezes it.
typedef ChatVideoPicker = Future<PickedVideo?> Function(PhotoSource source);

/// Whether the clipboard holds a picture, and the pictures on it; what the chat asks to paste. Where there is no clipboard
/// to ask (a browser tells the page what is pasted) these say there is nothing.
typedef ClipboardCheck = Future<bool> Function();
typedef ClipboardReader = Future<List<PickedPhoto>> Function();

Future<bool> noPhotosOnClipboard() async => false;

Future<List<PickedPhoto>> readNoClipboardPhotos() async => const [];

/// Whether a video can be turned left to right when it is made ready: native does it on the phones (Android, iPhone); a
/// browser sends the video as it is.
bool get chatVideoMirrorAvailable =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// Whether the camera can be asked for a photo: on the phones; a browser's picker has no camera of its own to ask for.
bool get chatCameraAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The system's photo picker, which needs no permission; the camera asks for its own. The files are not scaled by the
/// platform, which would make a GIF still.
Future<List<PickedPhoto>> pickChatPhotos(PhotoSource source) async {
  final picker = ImagePicker();
  try {
    final files = source == PhotoSource.camera
        ? [?await picker.pickImage(source: ImageSource.camera)]
        : await picker.pickMultiImage(
            limit: AlbumExtra.maxItems,
            requestFullMetadata: false,
          );
    return [
      for (final file in files.take(AlbumExtra.maxItems))
        PickedPhoto(await file.readAsBytes(), file.name),
    ];
  } on Object {
    // No permission for the camera, or no camera: nothing was picked
    return const [];
  }
}

/// The system's picker of videos, which needs no permission; the camera asks for its own and records for three minutes at
/// most. On a phone the video is a file ([PickedVideo.path]); in a browser it is read into memory.
Future<PickedVideo?> pickChatVideo(PhotoSource source) async {
  try {
    final file = await ImagePicker().pickVideo(
      source: source == PhotoSource.videoCamera ? ImageSource.camera : ImageSource.gallery,
      maxDuration: source == PhotoSource.videoCamera ? const Duration(minutes: 3) : null,
    );
    if (file == null) return null;
    return kIsWeb
        ? PickedVideo(bytes: await file.readAsBytes(), name: file.name)
        : PickedVideo(path: file.path, name: file.name);
  } on Object {
    // No permission for the camera, or no camera: nothing was picked
    return null;
  }
}
