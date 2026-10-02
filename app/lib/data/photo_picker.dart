import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Lets the person pick a picture from their photos; gives back its bytes, already small, or null when they back out.
typedef PhotoPicker = Future<Uint8List?> Function();

/// The system's own photo picker: it needs no permission, and the picture comes back scaled down to what an avatar needs.
Future<Uint8List?> pickPhoto() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 256,
    maxHeight: 256,
    imageQuality: 85,
  );
  return file?.readAsBytes();
}
