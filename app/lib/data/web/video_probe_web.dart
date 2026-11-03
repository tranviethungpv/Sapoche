import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../video_probe.dart';

/// Plays [bytes] in a `<video>` that is not on the page, to read its size and length and to draw a frame of it as the poster.
Future<VideoProbe?> probeVideo(Uint8List bytes, String name) async {
  final mime = name.toLowerCase().endsWith('.mov') ? 'video/quicktime' : 'video/mp4';
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)));
  final video = web.HTMLVideoElement()
    ..muted = true
    ..preload = 'auto'
    ..setAttribute('playsinline', '');
  try {
    final loaded = Completer<void>();
    video.onloadeddata = ((web.Event _) {
      if (!loaded.isCompleted) loaded.complete();
    }).toJS;
    video.onerror = ((web.Event _) {
      if (!loaded.isCompleted) loaded.completeError('unreadable');
    }).toJS;
    video.src = url;
    await loaded.future.timeout(const Duration(seconds: 15));
    final seconds = video.duration;
    if (seconds.isNaN || seconds.isInfinite || video.videoWidth == 0) return null;
    // A frame a little way in: the first one is often black
    final seeked = Completer<void>();
    video.onseeked = ((web.Event _) {
      if (!seeked.isCompleted) seeked.complete();
    }).toJS;
    video.currentTime = min(1.0, seconds / 10);
    await seeked.future.timeout(const Duration(seconds: 10));
    final scale = 480 / max(video.videoWidth, video.videoHeight);
    final width = max(1, (video.videoWidth * min(1.0, scale)).round());
    final height = max(1, (video.videoHeight * min(1.0, scale)).round());
    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(video, 0, 0, width, height);
    final done = Completer<web.Blob?>();
    canvas.toBlob(((web.Blob? blob) => done.complete(blob)).toJS, 'image/jpeg', 0.75.toJS);
    final blob = await done.future;
    if (blob == null) return null;
    return VideoProbe(
      w: video.videoWidth,
      h: video.videoHeight,
      durMs: (seconds * 1000).round(),
      poster: (await blob.arrayBuffer().toDart).toDart.asUint8List(),
    );
  } on Object {
    return null;
  } finally {
    video.removeAttribute('src');
    web.URL.revokeObjectURL(url);
  }
}
