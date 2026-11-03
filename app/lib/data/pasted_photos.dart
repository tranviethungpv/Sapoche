import 'chat_media.dart' show PickedPhoto;
import 'pasted_photos_native.dart' if (dart.library.js_interop) 'web/pasted_photos_web.dart' as platform;

/// Calls [onPhotos] with the pictures the person pastes into the page, for as long as it is listened to. Only a browser
/// tells the page what is pasted (Ctrl+V, or Paste in its menu); on a phone the app asks the clipboard itself. Gives back
/// the function that stops listening.
void Function() listenForPastedPhotos(void Function(List<PickedPhoto> photos) onPhotos) =>
    platform.listenForPastedPhotos(onPhotos);
