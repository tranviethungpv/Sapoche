import 'dart:typed_data';

import 'package:gal/gal.dart';

/// Saves [bytes] to the phone's gallery. True when saved, false when it went wrong, null when the person did not allow it.
Future<bool?> saveToDevice(Uint8List bytes, String name, String mime) async {
  try {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) return null;
    await Gal.putImageBytes(bytes, name: name);
    return true;
  } on GalException catch (e) {
    return e.type == GalExceptionType.accessDenied ? null : false;
  } on Object {
    return false;
  }
}
