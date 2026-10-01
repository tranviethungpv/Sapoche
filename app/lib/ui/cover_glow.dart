import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The soft, blurred picture of a cover that lights the full player's background, the way Apple Music does: the
/// cover itself, enlarged, blurred, more vivid and darkened until white text reads well on any colours.
///
/// The cover is shrunk to a few dozen pixels, blurred and tinted once into a small picture, which is then just
/// stretched over the screen. Nothing is blurred while the player is open, so it costs nothing per frame.
class CoverGlow {
  CoverGlow._();

  /// Size of the finished picture; it is stretched, and stretching a smooth picture stays smooth.
  static const width = 72;
  static const height = 156;

  /// Side of the cover that is read, in pixels.
  static const _side = 48;

  /// How vivid the colours are made.
  static const saturation = 1.75;

  /// The brightness the background should average, 0 black to 1 white.
  static const _targetLuma = 0.30;

  /// In the order they were last used, the oldest first (a map literal keeps the order of insertion).
  static final _cache = <String, ui.Image?>{};
  static final _pending = <String, Future<ui.Image?>>{};
  static const _kept = 8;

  /// The blurred picture for the cover at [url], or null when the cover cannot be read.
  static Future<ui.Image?> of(String url) {
    if (_cache.containsKey(url)) {
      // Most recently used goes last
      final image = _cache.remove(url);
      _cache[url] = image;
      return Future.value(image);
    }
    return _pending.putIfAbsent(url, () async {
      final image = await _make(url);
      _remember(url, image);
      _pending.remove(url);
      return image;
    });
  }

  static void _remember(String url, ui.Image? image) {
    _cache[url] = image;
    while (_cache.length > _kept) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }
  }

  static Future<ui.Image?> _make(String url) async {
    final small = await _load(url);
    if (small == null) return null;
    try {
      return await render(small);
    } finally {
      small.dispose();
    }
  }

  static Future<ui.Image?> _load(String url) async {
    final completer = Completer<ui.Image?>();
    final stream = ResizeImage(
      NetworkImage(url),
      width: _side,
      height: _side,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        // The stream owns this image and may drop it: keep a copy
        if (!completer.isCompleted) completer.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  /// Blurs and tints [cover] into the small picture. Public so that it can be tested with a made-up cover.
  static Future<ui.Image> render(ui.Image cover) async {
    final data = await cover.toByteData(format: ui.ImageByteFormat.rawRgba);
    final luma = data == null ? 0.5 : averageLuma(data.buffer.asUint8List());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: 5,
        sigmaY: 5,
        tileMode: TileMode.mirror,
      )
      ..colorFilter = ColorFilter.matrix(tint(darkening(luma)));
    // The cover fills the height and is cropped at the sides, as it would be on a tall screen
    final target = Rect.fromCenter(
      center: const Offset(width / 2, height / 2),
      width: height.toDouble(),
      height: height.toDouble(),
    );
    canvas.drawImageRect(
      cover,
      Rect.fromLTWH(0, 0, cover.width.toDouble(), cover.height.toDouble()),
      target,
      paint,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  /// How bright the pixels are on average, 0 to 1, from raw RGBA.
  static double averageLuma(Uint8List rgba) {
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      sum +=
          (0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2]) /
          255;
      count++;
    }
    return count == 0 ? 0.5 : sum / count;
  }

  /// By how much to darken a cover of this [luma]: a pale cover a lot, a dark one hardly at all.
  static double darkening(double luma) =>
      (_targetLuma / (luma <= 0.01 ? 0.01 : luma)).clamp(0.38, 0.9);

  /// A colour matrix that makes colours more vivid and then darkens them by [factor].
  static List<double> tint(double factor) {
    const s = saturation;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    double k(double v) => v * factor;
    return [
      k(r * (1 - s) + s),
      k(g * (1 - s)),
      k(b * (1 - s)),
      0,
      0,
      k(r * (1 - s)),
      k(g * (1 - s) + s),
      k(b * (1 - s)),
      0,
      0,
      k(r * (1 - s)),
      k(g * (1 - s)),
      k(b * (1 - s) + s),
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}
