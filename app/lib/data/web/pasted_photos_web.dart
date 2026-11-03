import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../chat_media.dart' show PickedPhoto;

/// Listens for the browser's `paste` event, which Ctrl+V and the Paste of its menu both raise, and takes the pictures out
/// of it (a screenshot, a copied image, several files copied in a folder). Words are left to the field; so is a paste with
/// words and pictures together, which is a page copied, not a picture.
void Function() listenForPastedPhotos(void Function(List<PickedPhoto> photos) onPhotos) {
  final listener = ((web.Event event) {
    final data = (event as web.ClipboardEvent).clipboardData;
    if (data == null) return;
    final items = data.items;
    final files = <web.File>[];
    var hasText = false;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind == 'string' && item.type == 'text/plain') hasText = true;
      if (item.kind != 'file') continue;
      final file = item.getAsFile();
      if (file != null && _isPicture(file)) files.add(file);
    }
    if (files.isEmpty || hasText) return;
    event.preventDefault();
    unawaited(
      _read(files).then((photos) {
        if (photos.isNotEmpty) onPhotos(photos);
      }),
    );
  }).toJS;
  // Before the field gets it: a picture is no text, and the field would swallow it
  web.document.addEventListener('paste', listener, true.toJS);
  return () => web.document.removeEventListener('paste', listener, true.toJS);
}

/// A file copied to the clipboard is a picture by its type, or by its name where the browser does not know the type (HEIC).
bool _isPicture(web.File file) =>
    file.type.startsWith('image/') || RegExp(r'\.(heic|heif|avif|jxl|svg)$', caseSensitive: false).hasMatch(file.name);

Future<List<PickedPhoto>> _read(List<web.File> files) async {
  final photos = <PickedPhoto>[];
  for (final file in files) {
    try {
      var bytes = (await file.arrayBuffer().toDart).toDart.asUint8List();
      // A format the app does not read is redrawn by the browser, which knows more of them
      if (!_readByApp(bytes)) bytes = await _redraw(file) ?? bytes;
      final name = file.name.isEmpty ? 'pasted-${photos.length + 1}' : file.name;
      photos.add(PickedPhoto(bytes, name));
    } on Object {
      // Not readable: left out, as a picture the app cannot read would be
    }
  }
  return photos;
}

/// Whether [b] starts as a JPEG, PNG, GIF, WebP, BMP or TIFF, which the app reads itself (a GIF that moves must not be redrawn).
bool _readByApp(Uint8List b) {
  if (b.length < 12) return false;
  bool at(int i, String text) {
    for (var k = 0; k < text.length; k++) {
      if (b[i + k] != text.codeUnitAt(k)) return false;
    }
    return true;
  }

  return (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ||
      (b[0] == 0x89 && at(1, 'PNG')) ||
      at(0, 'GIF8') ||
      at(0, 'BM') ||
      (at(0, 'RIFF') && at(8, 'WEBP')) ||
      (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) ||
      (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A);
}

/// [file] drawn by the browser and given back as a PNG; null when the browser cannot show it either.
Future<Uint8List?> _redraw(web.File file) async {
  final url = web.URL.createObjectURL(file);
  try {
    final image = web.HTMLImageElement()..src = url;
    await image.decode().toDart;
    // A picture of lines (SVG) may say no size
    final width = image.naturalWidth > 0 ? image.naturalWidth : 1024;
    final height = image.naturalHeight > 0 ? image.naturalHeight : 1024;
    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(image, 0, 0, width, height);
    final done = Completer<web.Blob?>();
    canvas.toBlob(((web.Blob? blob) => done.complete(blob)).toJS, 'image/png');
    final blob = await done.future;
    if (blob == null) return null;
    return (await blob.arrayBuffer().toDart).toDart.asUint8List();
  } on Object {
    return null;
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
