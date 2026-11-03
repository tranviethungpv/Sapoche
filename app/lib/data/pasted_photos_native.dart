import 'chat_media.dart' show PickedPhoto;

/// A phone tells the page nothing of what is pasted: the chat asks the clipboard through the backend.
void Function() listenForPastedPhotos(void Function(List<PickedPhoto> photos) onPhotos) => () {};
