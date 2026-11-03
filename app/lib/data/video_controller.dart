import 'package:video_player/video_player.dart';

import 'chat_media.dart' show VideoSource;
import 'video_controller_native.dart' if (dart.library.js_interop) 'web/video_controller_web.dart' as platform;

/// A player for [source], and what to call when it is done with (a browser holds the bytes under an address until then).
({VideoPlayerController controller, void Function() release}) videoControllerFor(VideoSource source) =>
    platform.videoControllerFor(source);
