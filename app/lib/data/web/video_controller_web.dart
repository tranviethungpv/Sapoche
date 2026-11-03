import 'dart:js_interop';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import '../chat_media.dart' show VideoSource;

({VideoPlayerController controller, void Function() release}) videoControllerFor(VideoSource source) {
  final blob = web.Blob([source.bytes!.toJS].toJS, web.BlobPropertyBag(type: 'video/mp4'));
  final url = web.URL.createObjectURL(blob);
  return (controller: VideoPlayerController.networkUrl(Uri.parse(url)), release: () => web.URL.revokeObjectURL(url));
}
