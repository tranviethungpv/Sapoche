import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The colour that stands out most in a cover, used to tint the player's background.
///
/// It shrinks the image to a handful of pixels and averages them, weighting each by how vivid and how
/// mid-toned it is, so a mostly white or black cover with a small coloured detail still gives that
/// detail's colour. Results are remembered per URL.
class CoverColor {
  CoverColor._();

  static final _cache = <String, Color?>{};
  static final _pending = <String, Future<Color?>>{};

  /// The cover's colour, or null when the image cannot be read or has no colour to speak of.
  static Future<Color?> of(String url) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    return _pending.putIfAbsent(url, () async {
      final color = await _extract(url);
      _cache[url] = color;
      _pending.remove(url);
      return color;
    });
  }

  static Future<Color?> _extract(String url) async {
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
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data == null ? null : fromPixels(data.buffer.asUint8List());
  }

  static const _side = 24;

  /// Picks the colour out of raw RGBA pixels. Public so it can be tested without decoding an image.
  static Color? fromPixels(Uint8List rgba) {
    var r = 0.0, g = 0.0, b = 0.0, total = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      final hsv = HSVColor.fromColor(
        Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]),
      );
      // Vivid colours count for more; near black and near white barely count at all
      final weight =
          hsv.saturation * (1 - (hsv.value - 0.6).abs() * 1.6).clamp(0.0, 1.0);
      r += rgba[i] * weight;
      g += rgba[i + 1] * weight;
      b += rgba[i + 2] * weight;
      total += weight;
    }
    // Less than about one vivid pixel out of a hundred: a grey cover has no colour to offer
    if (total < (rgba.length / 4) * 0.01) return null;
    return Color.fromARGB(
      255,
      (r / total).round(),
      (g / total).round(),
      (b / total).round(),
    );
  }
}
