import 'dart:typed_data';

import 'video_probe.dart';

/// A phone's native side reads the video itself (see Backend.prepareVideo).
Future<VideoProbe?> probeVideo(Uint8List bytes, String name) async => null;
