import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../cover_glow.dart';
import 'wash.dart';

/// Background of the full player, in the manner of Apple Music: the cover's own colours, enlarged and blurred
/// until they are only light, with the bottom darkened for the controls. It changes from song to song by fading
/// from one picture to the next. A song with no cover, or one that cannot be read, gets the app's pink veil.
///
/// The picture is made once per cover (see [CoverGlow]) and is not drawn again until the song changes, so the
/// player costs no more with it than without.
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({super.key, required this.coverUrl});

  final String? coverUrl;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop> {
  /// The picture on show and the address it is of; kept while the next one is being made.
  ui.Image? _glow;
  String? _shownFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.coverUrl != old.coverUrl) _load();
  }

  void _load() {
    final url = widget.coverUrl;
    if (url == null) {
      setState(() {
        _glow = null;
        _shownFor = null;
      });
      return;
    }
    CoverGlow.of(url).then((image) {
      if (!mounted || widget.coverUrl != url) return;
      setState(() {
        _glow = image;
        _shownFor = url;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glow = _glow;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: p.base),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: glow == null
              ? const PinkWash(
                  key: ValueKey('pink'),
                  intensity: 0.55,
                  opaque: false,
                  child: SizedBox.expand(),
                )
              : RepaintBoundary(
                  key: ValueKey(_shownFor),
                  child: CustomPaint(
                    painter: _GlowPainter(glow),
                    child: const SizedBox.expand(),
                  ),
                ),
        ),
        // Darker towards the bottom, where the controls are
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.45, 1],
              colors: [Color(0x14000000), Color(0x26000000), Color(0x73000000)],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      // Stretched far, so it is smoothed the best way there is
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.image != image;
}
