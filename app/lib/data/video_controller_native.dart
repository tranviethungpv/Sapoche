import 'dart:io';

import 'package:video_player/video_player.dart';

import 'chat_media.dart' show VideoSource;

({VideoPlayerController controller, void Function() release}) videoControllerFor(VideoSource source) =>
    (controller: VideoPlayerController.file(File(source.path!)), release: () {});
