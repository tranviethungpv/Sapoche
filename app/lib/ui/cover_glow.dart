import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'widgets/cached_cover.dart';

/// The soft, blurred picture of a cover that lights the full player's background, the way Apple Music does: the
/// cover itself, enlarged, blurred and more vivid. In the dark theme it is darkened until white text reads well on
/// any colours; in the light theme it is faded towards white until dark text does.
///
/// The cover is shrunk to a few dozen pixels, blurred and tinted once into a small picture, which is then just
/// stretched over the screen. Nothing is blurred while the player is open, so it costs nothing per frame.
///
/// The glow along the top of the browsing pages is made differently ([top]): not from the shape of the cover, which
/// shows as a smear of faces when it is stretched across a page, but from a coarse grid of its colours.
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

  /// How vivid the colours are made in the light theme: less than in the dark one, where they have a dark ground to
  /// glow on, as against pale ones that turn garish.
  static const _lightSaturation = 1.35;

  /// The brightness the background should average in the light theme, 0 black to 1 white: pale enough for dark text.
  static const _lightLuma = 0.62;

  /// Size of the picture of the glow along the top. Its shape does not matter: it is made of a few soft patches of
  /// colour, which stay soft however far they are stretched.
  static const topWidth = 64;
  static const topHeight = 48;

  /// The colours of the cover are taken in a grid of this many cells on a side.
  static const grid = 5;

  /// How vivid the colours of the glow are made in the light theme. More than [_lightSaturation]: averaged, the colours
  /// of a cover turn dull, and on white they turn grey.
  static const _topLightSaturation = 1.6;

  /// In the order they were last used, the oldest first (a map literal keeps the order of insertion).
  static final _cache = <String, ui.Image?>{};
  static final _pending = <String, Future<ui.Image?>>{};
  static const _kept = 12;

  /// The blurred picture for the cover at [url], pale when [light], or null when the cover cannot be read.
  static Future<ui.Image?> of(String url, {bool light = false}) =>
      _of(url, light, false);

  /// The glow along the top for the cover at [url]: see [renderTop].
  static Future<ui.Image?> top(String url, {bool light = false}) =>
      _of(url, light, true);

  /// The same mesh of colours for the whole of a page, not faded away: the background of the pages of an album, an
  /// artist or a playlist.
  static Future<ui.Image?> page(String url, {bool light = false}) =>
      _of(url, light, true, page: true);

  static Future<ui.Image?> _of(
    String url,
    bool light,
    bool top, {
    bool page = false,
  }) {
    final key =
        '${page ? 'page ' : top ? 'top ' : ''}${light ? 'light' : 'dark'} $url';
    if (_cache.containsKey(key)) {
      // Most recently used goes last
      final image = _cache.remove(key);
      _cache[key] = image;
      return Future.value(image);
    }
    return _pending.putIfAbsent(key, () async {
      final image = await _make(url, light, top, page: page);
      _remember(key, image);
      _pending.remove(key);
      return image;
    });
  }

  static void _remember(String key, ui.Image? image) {
    _cache[key] = image;
    while (_cache.length > _kept) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }
  }

  static Future<ui.Image?> _make(
    String url,
    bool light,
    bool top, {
    bool page = false,
  }) async {
    final small = await _load(url);
    if (small == null) return null;
    try {
      return top
          ? await renderTop(small, light: light, page: page)
          : await render(small, light: light);
    } finally {
      small.dispose();
    }
  }

  static Future<ui.Image?> _load(String url) async {
    final completer = Completer<ui.Image?>();
    final stream = ResizeImage(
      CachedCover(url),
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
  static Future<ui.Image> render(ui.Image cover, {bool light = false}) async {
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
      ..colorFilter = ColorFilter.matrix(
        light
            ? tint(
                lightKeep(luma),
                lift: 1 - lightKeep(luma),
                saturation: _lightSaturation,
              )
            : tint(darkening(luma)),
      );
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

  /// The glow along the top of a page, in the manner of Apple Music's mesh of colours: the cover is not blurred but
  /// reduced to a [grid] of patches of colour, which are smoothed into one another. No shape of the cover is left (a
  /// face stretched across a page is a smear), only where its colours are, and they are brought up as in [render]. It
  /// is faded from the top to nothing, so that it can be drawn as it is; or, for a [page], only to a softer hold over the
  /// whole of it. Public so that it can be tested.
  static Future<ui.Image> renderTop(
    ui.Image cover, {
    bool light = false,
    bool page = false,
  }) async {
    final data = await cover.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = data?.buffer.asUint8List() ?? Uint8List(0);
    final luma = averageLuma(rgba);
    final keep = lightKeep(luma);
    final tone = light
        ? tint(keep, lift: 1 - keep, saturation: _topLightSaturation)
        : tint(darkening(luma));
    final lift = light ? bright(1, 1.15) : bright(1.15, 1);
    final cells = gridColors(rgba, cover.width, cover.height);

    const w = topWidth + 0.0, h = topHeight + 0.0;
    const area = Rect.fromLTWH(0, 0, w, h);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..saveLayer(area, Paint())
      ..saveLayer(
        area,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 6.5,
            sigmaY: 6.5,
            tileMode: TileMode.clamp,
          ),
      );
    for (var i = 0; i < grid * grid; i++) {
      final column = i % grid, row = i ~/ grid;
      // The cells at the edge run on past it, so that the blur has colour to take there and not nothing
      final left = column == 0 ? -w : w * column / grid;
      final right = column == grid - 1 ? 2 * w : w * (column + 1) / grid;
      final top = row == 0 ? -h : h * row / grid;
      final bottom = row == grid - 1 ? 2 * h : h * (row + 1) / grid;
      canvas.drawRect(
        Rect.fromLTRB(left, top, right, bottom),
        Paint()..color = _through(lift, _through(tone, cells[i])),
      );
    }
    canvas
      ..restore()
      ..drawRect(
        area,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            area.topCenter,
            area.bottomCenter,
            page
                ? const [Color(0x99FFFFFF), Color(0x80FFFFFF), Color(0x66FFFFFF)]
                : const [Color(0x99FFFFFF), Color(0x52FFFFFF), Color(0x00FFFFFF)],
            const [0, 0.5, 1],
          ),
      )
      ..restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(topWidth, topHeight);
    picture.dispose();
    return image;
  }

  /// The colour of each cell of a [grid] by [grid] division of a picture, row by row, from raw RGBA: the mean of its
  /// pixels, counting the vivid and the light ones for more. A plain mean of red and green is a muddy brown, and of a
  /// black bar around a video's picture a dark patch; this one keeps to the colours that the eye takes the cover for.
  static List<Color> gridColors(Uint8List rgba, int width, int height) {
    final sum = List.filled(grid * grid * 4, 0.0);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = (y * width + x) * 4;
        if (at + 3 >= rgba.length || rgba[at + 3] < 128) continue;
        final r = rgba[at], g = rgba[at + 1], b = rgba[at + 2];
        final high = math.max(r, math.max(g, b));
        final low = math.min(r, math.min(g, b));
        final vivid = high == 0 ? 0.0 : (high - low) / high;
        final weight = (0.2 + vivid) * (0.25 + high / 255);
        final cell = (y * grid ~/ height) * grid + x * grid ~/ width;
        sum[cell * 4] += r * weight;
        sum[cell * 4 + 1] += g * weight;
        sum[cell * 4 + 2] += b * weight;
        sum[cell * 4 + 3] += weight;
      }
    }
    return [
      for (var i = 0; i < grid * grid; i++)
        sum[i * 4 + 3] == 0
            ? const Color(0xFF808080)
            : Color.fromARGB(
                255,
                (sum[i * 4] / sum[i * 4 + 3]).round(),
                (sum[i * 4 + 1] / sum[i * 4 + 3]).round(),
                (sum[i * 4 + 2] / sum[i * 4 + 3]).round(),
              ),
    ];
  }

  /// [color] after the colour matrix [m].
  static Color _through(List<double> m, Color color) {
    final r = color.r * 255, g = color.g * 255, b = color.b * 255;
    int channel(int row) =>
        (m[row * 5] * r +
                m[row * 5 + 1] * g +
                m[row * 5 + 2] * b +
                m[row * 5 + 4])
            .round()
            .clamp(0, 255);
    return Color.fromARGB(255, channel(0), channel(1), channel(2));
  }

  /// A colour matrix that multiplies the colours by [gain] and makes them [vivid] times as vivid.
  static List<double> bright(double gain, double vivid) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final s = vivid;
    double k(double v) => v * gain;
    return [
      k(r * (1 - s) + s), k(g * (1 - s)), k(b * (1 - s)), 0, 0, //
      k(r * (1 - s)), k(g * (1 - s) + s), k(b * (1 - s)), 0, 0, //
      k(r * (1 - s)), k(g * (1 - s)), k(b * (1 - s) + s), 0, 0, //
      0, 0, 0, 1, 0,
    ];
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

  /// How much of the colour of a cover of this [luma] is kept in the light theme, the rest being white: a dark cover
  /// is faded a lot to stay pale, a light or colourful one keeps more of its colours.
  static double lightKeep(double luma) =>
      ((1 - _lightLuma) / (1 - (luma > 0.9 ? 0.9 : luma))).clamp(0.38, 0.75);

  /// A colour matrix that makes colours more vivid, darkens them by [factor] and then mixes in [lift] of white.
  static List<double> tint(
    double factor, {
    double lift = 0,
    double saturation = CoverGlow.saturation,
  }) {
    final s = saturation;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    double k(double v) => v * factor;
    final white = lift * 255;
    return [
      k(r * (1 - s) + s),
      k(g * (1 - s)),
      k(b * (1 - s)),
      0,
      white,
      k(r * (1 - s)),
      k(g * (1 - s) + s),
      k(b * (1 - s)),
      0,
      white,
      k(r * (1 - s)),
      k(g * (1 - s)),
      k(b * (1 - s) + s),
      0,
      white,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}
