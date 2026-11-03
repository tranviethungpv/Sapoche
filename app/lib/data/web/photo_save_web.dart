import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Has the browser download [bytes] as a file. True once the download was asked for.
Future<bool?> saveToDevice(Uint8List bytes, String name, String mime) async {
  try {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
    final url = web.URL.createObjectURL(blob);
    final link = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = '$name.${_extension(mime)}';
    web.document.body?.append(link);
    link.click();
    link.remove();
    web.URL.revokeObjectURL(url);
    return true;
  } on Object {
    return false;
  }
}

String _extension(String mime) => switch (mime) {
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  'video/mp4' => 'mp4',
  _ => 'jpg',
};
