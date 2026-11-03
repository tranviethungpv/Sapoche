import 'dart:typed_data';

import 'video_probe_native.dart' if (dart.library.js_interop) 'web/video_probe_web.dart' as platform;

/// What a browser can tell of a video: its size in pixels, its length, and a picture from it.
class VideoProbe {
  const VideoProbe({required this.w, required this.h, required this.durMs, required this.poster});

  final int w;
  final int h;
  final int durMs;

  /// A JPEG.
  final Uint8List poster;
}

/// Opens [bytes] as a video in the page and reads what it says; null when the browser cannot play it (a format it does not
/// know, a damaged file). Only a browser does this: a phone's native side squeezes the video and answers the same.
Future<VideoProbe?> probeVideo(Uint8List bytes, String name) => platform.probeVideo(bytes, name);
