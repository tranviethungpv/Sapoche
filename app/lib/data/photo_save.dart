import 'dart:typed_data';

import 'photo_save_native.dart' if (dart.library.js_interop) 'web/photo_save_web.dart' as platform;

/// How saving a picture went.
enum PhotoSaveResult { saved, denied, failed }

/// Saves a picture: [bytes] as they are, named [name] (no extension; [mime] says which one).
typedef PhotoSaver = Future<PhotoSaveResult> Function(Uint8List bytes, String name, String mime);

/// Puts a picture in the phone's gallery, or in a browser's downloads.
Future<PhotoSaveResult> savePhoto(Uint8List bytes, String name, String mime) async {
  final saved = await platform.saveToDevice(bytes, name, mime);
  return switch (saved) {
    true => PhotoSaveResult.saved,
    false => PhotoSaveResult.failed,
    null => PhotoSaveResult.denied,
  };
}
