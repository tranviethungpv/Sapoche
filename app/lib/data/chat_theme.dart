import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// The look of a room's chat, as two colours. The room keeps only its [id], a short text: the name of one of the
/// [presets], or `c-` and the hex of the colours taken from a photo, so a photo itself never goes anywhere.
class ChatTheme {
  const ChatTheme(this.id, this.from, this.to);

  /// What the room keeps: `default` when the chat keeps the colours of the app.
  final String id;

  /// The colour of the messages of this device, and the one the rest is tinted with.
  final Color from;

  /// The colour its gradient ends in.
  final Color to;

  /// The id of the colours of the app itself: no theme.
  static const none = 'default';

  static const presets = [
    ChatTheme('ocean', Color(0xFF1E88E5), Color(0xFF00ACC1)),
    ChatTheme('sunset', Color(0xFFF4511E), Color(0xFFD81B60)),
    ChatTheme('forest', Color(0xFF2E7D32), Color(0xFF00897B)),
    ChatTheme('grape', Color(0xFF7E57C2), Color(0xFFAB47BC)),
    ChatTheme('honey', Color(0xFFF9A825), Color(0xFFEF6C00)),
    ChatTheme('mono', Color(0xFF455A64), Color(0xFF78909C)),
  ];

  /// The id of the theme made of [from] and [to], which is what a photo gives.
  factory ChatTheme.custom(Color from, Color to) =>
      ChatTheme('c-${_hex(from)}-${_hex(to)}', from, to);

  /// The theme for an id the room sent, or null for the default and for an id this version does not know.
  static ChatTheme? parse(String? id) {
    if (id == null || id == none) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    final custom = RegExp(r'^c-([0-9a-f]{6})-([0-9a-f]{6})$').firstMatch(id);
    if (custom == null) return null;
    return ChatTheme(
      id,
      Color(0xFF000000 | int.parse(custom[1]!, radix: 16)),
      Color(0xFF000000 | int.parse(custom[2]!, radix: 16)),
    );
  }

  static String _hex(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

  /// The theme with the colours that stand out in the picture [photo]; null when it cannot be read.
  static Future<ChatTheme?> fromPhoto(Uint8List photo) async {
    try {
      final codec = await ui.instantiateImageCodec(photo, targetWidth: _side);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData();
      frame.image.dispose();
      codec.dispose();
      if (data == null) return null;
      final (from, to) = standOut(data.buffer.asUint8List());
      return ChatTheme.custom(from, to);
    } catch (_) {
      return null;
    }
  }

  /// Side of the picture that is read, in pixels.
  static const _side = 48;

  static const _bins = 12;

  /// The two colours that stand out in [rgba], the bytes of a picture: red, green, blue and alpha for each pixel.
  /// A colour counts for as much as it is vivid and bright, so a grey sky does not outweigh a red kite. The second
  /// is of a different hue when the picture has one worth the name, and a near one otherwise.
  static (Color, Color) standOut(Uint8List rgba) {
    final weight = List.filled(_bins, 0.0);
    final sum = List.generate(_bins, (_) => [0.0, 0.0, 0.0]);
    var greyWeight = 0.0;
    final grey = [0.0, 0.0, 0.0];
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      final color = HSVColor.fromColor(
        Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]),
      );
      final vivid = color.saturation * color.value;
      final isGrey = vivid < 0.08;
      final bin = (color.hue / 360 * _bins).floor() % _bins;
      final into = isGrey ? grey : sum[bin];
      final by = isGrey ? 1.0 : vivid;
      if (isGrey) {
        greyWeight += 1;
      } else {
        weight[bin] += vivid;
      }
      for (var c = 0; c < 3; c++) {
        into[c] += rgba[i + c] * by;
      }
    }
    Color mean(List<double> total, double of) => Color.fromARGB(
      255,
      (total[0] / of).round().clamp(0, 255),
      (total[1] / of).round().clamp(0, 255),
      (total[2] / of).round().clamp(0, 255),
    );
    final best = weight.indexOf(weight.reduce((a, b) => a > b ? a : b));
    if (weight[best] == 0) {
      // A picture without colour: its greys
      final base = greyWeight == 0
          ? const Color(0xFF455A64)
          : mean(grey, greyWeight);
      final hsv = HSVColor.fromColor(base);
      return (
        hsv.withValue(hsv.value.clamp(0.25, 0.6)).toColor(),
        hsv.withValue((hsv.value + 0.25).clamp(0.45, 0.85)).toColor(),
      );
    }
    final first = _vivid(mean(sum[best], weight[best]));
    // Another hue, at least two bins away, that has a quarter of what the first one has
    var other = -1;
    for (var i = 0; i < _bins; i++) {
      final apart = (i - best).abs();
      if (apart < 2 || _bins - apart < 2) continue;
      if (weight[i] >= weight[best] * 0.25 &&
          (other < 0 || weight[i] > weight[other])) {
        other = i;
      }
    }
    final second = other < 0
        ? _vivid(
            HSVColor.fromColor(first)
                .withHue((HSVColor.fromColor(first).hue + 28) % 360)
                .toColor(),
          )
        : _vivid(mean(sum[other], weight[other]));
    return (first, second);
  }

  /// [color] made vivid enough to carry white words and to be told from a grey.
  static Color _vivid(Color color) {
    final hsv = HSVColor.fromColor(color);
    return hsv
        .withSaturation(hsv.saturation.clamp(0.45, 0.9))
        .withValue(hsv.value.clamp(0.45, 0.85))
        .toColor();
  }
}
