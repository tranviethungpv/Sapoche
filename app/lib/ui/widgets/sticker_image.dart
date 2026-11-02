import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/calm.dart';
import '../scope.dart';
import 'on_screen.dart';

/// A sticker of a pack, [size] logical pixels square. An animated one loops while it is on screen; it stands still (on a
/// frame of its own) once it is scrolled out of sight, when the system asks for no animations, when the app wants calm,
/// or when [animate] is off. Where the sticker cannot be had (no pack, no network, gone from the server) the emoji it
/// stands for is drawn in its place.
class StickerImage extends StatefulWidget {
  const StickerImage({
    super.key,
    required this.pack,
    required this.id,
    required this.emoji,
    required this.size,
    this.animate = true,
  });

  final String pack;
  final String id;
  final String emoji;
  final double size;
  final bool animate;

  @override
  State<StickerImage> createState() => _StickerImageState();
}

class _StickerImageState extends State<StickerImage> {
  Uint8List? _bytes;
  bool _failed = false;

  /// The first frame has been drawn, so a picture that is to stand still can stop.
  bool _drawn = false;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(StickerImage old) {
    super.didUpdateWidget(old);
    if (old.pack != widget.pack || old.id != widget.id) {
      _bytes = null;
      _failed = false;
      _drawn = false;
      _fetch();
    }
  }

  void _fetch() {
    final asked = ++_asked;
    AppScope.of(context).stickers.image(widget.pack, widget.id).then((bytes) {
      if (!mounted || asked != _asked) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return OnScreen(
      builder: (context, visible) {
        final allowed = widget.animate && visible && !MediaQuery.disableAnimationsOf(context);
        return ValueListenableBuilder<bool>(
          valueListenable: Calm.on,
          builder: (context, calm, _) => _picture(context, allowed && !calm),
        );
      },
    );
  }

  Widget _picture(BuildContext context, bool playing) {
    final bytes = _bytes;
    final size = widget.size;
    final Widget child;
    if (bytes != null) {
      child = Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.contain,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, sync) {
          if ((sync || frame != null) && !_drawn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_drawn) setState(() => _drawn = true);
            });
          }
          return child;
        },
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else if (_failed) {
      child = _fallback();
    } else {
      child = const SizedBox.shrink();
    }
    return Semantics(
      label: widget.emoji,
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        // An animated picture is stopped by taking away its tickers; it needs them until its first frame is drawn
        child: TickerMode(enabled: playing || !_drawn, child: child),
      ),
    );
  }

  Widget _fallback() => Center(
    child: FittedBox(
      child: Text(
        widget.emoji,
        key: const ValueKey('sticker-fallback'),
        style: TextStyle(fontSize: widget.size * 0.7),
      ),
    ),
  );
}
