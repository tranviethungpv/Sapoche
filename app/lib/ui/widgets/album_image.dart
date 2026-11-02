import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/chat_extra.dart';
import '../../data/chat_media.dart';
import '../../theme/theme.dart';

/// One picture of a message as the chat shows it: a picture of the room (fetched when wanted) or one this device is
/// still sending (its bytes are at hand).
class AlbumSlot {
  const AlbumSlot._({
    required this.id,
    required this.mime,
    required this.aspect,
    required this.th,
    this.item,
    this.bytes,
  });

  factory AlbumSlot.item(AlbumItem item) =>
      AlbumSlot._(id: item.m, mime: item.mime, aspect: item.aspect, th: item.th, item: item);

  /// The [index]th of the photos being sent.
  factory AlbumSlot.photo(PreparedPhoto photo, int index) => AlbumSlot._(
    id: 'local-$index',
    mime: photo.mime,
    aspect: photo.h <= 0 || photo.w <= 0 ? 1 : (photo.w / photo.h).clamp(0.5, 2.0),
    th: photo.th,
    bytes: photo.bytes,
  );

  /// The file's id in the room, or a stand-in for a picture not sent yet.
  final String id;
  final String mime;

  /// Width over height, kept within what a bubble can show.
  final double aspect;

  /// The tiny picture shown blurred until the real one is here, as base64.
  final String th;
  final AlbumItem? item;
  final Uint8List? bytes;

  bool get animated => mime != 'image/jpeg';

  /// The picture itself, null when it cannot be had.
  Future<Uint8List?> load(ChatMedia media, String room) {
    final here = bytes;
    if (here != null) return Future.value(here);
    return media.open(room, item!);
  }
}

/// A picture of an [AlbumSlot], filling the space it is given: its tiny blurred version first, then the picture. An
/// animated one moves only while [playing]; until then it shows its first frame.
class AlbumImage extends StatefulWidget {
  const AlbumImage({
    super.key,
    required this.slot,
    required this.media,
    required this.room,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.playing = false,
    this.backdrop = true,
  });

  final AlbumSlot slot;
  final ChatMedia media;
  final String room;
  final BoxFit fit;

  /// Decode the picture no wider than this many pixels: a small place needs no more.
  final int? cacheWidth;
  final bool playing;

  /// Paint a plain colour behind the picture, for the places it does not fill.
  final bool backdrop;

  @override
  State<AlbumImage> createState() => _AlbumImageState();
}

class _AlbumImageState extends State<AlbumImage> {
  Uint8List? _bytes;
  Uint8List? _thumb;
  bool _failed = false;

  /// The real picture has drawn once, so the tiny one under it can go.
  bool _ready = false;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _thumb = _decodeThumb();
    _fetch();
  }

  @override
  void didUpdateWidget(AlbumImage old) {
    super.didUpdateWidget(old);
    if (old.slot.id != widget.slot.id || old.room != widget.room) {
      _thumb = _decodeThumb();
      _failed = false;
      // The picture shown stays until the new one is here: a message that was being sent becomes the room's with no flash
      _fetch();
    }
  }

  Uint8List? _decodeThumb() {
    try {
      return widget.slot.th.isEmpty ? null : base64.decode(widget.slot.th);
    } on FormatException {
      return null;
    }
  }

  void _fetch() {
    final slot = widget.slot;
    final here = slot.bytes;
    if (here != null) {
      _bytes = here;
      return;
    }
    final asked = ++_asked;
    slot.load(widget.media, widget.room).then((bytes) {
      if (!mounted || asked != _asked) return;
      setState(() {
        if (bytes == null) {
          _failed = _bytes == null;
        } else {
          _bytes = bytes;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bytes = _bytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.backdrop) ColoredBox(color: p.surface),
        if (!_ready && _thumb != null)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5, tileMode: TileMode.clamp),
            child: Image.memory(
              _thumb!,
              fit: widget.fit,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        if (bytes != null)
          // An animated picture is stopped by taking away its tickers: it keeps its first frame
          TickerMode(
            enabled: widget.playing,
            child: Image.memory(
              bytes,
              fit: widget.fit,
              cacheWidth: widget.cacheWidth,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, sync) {
                if ((sync || frame != null) && !_ready) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_ready) setState(() => _ready = true);
                  });
                }
                return child;
              },
              errorBuilder: (_, _, _) => _Broken(color: p.textTertiary),
            ),
          )
        else if (_failed)
          _Broken(color: p.textTertiary),
      ],
    );
  }
}

class _Broken extends StatelessWidget {
  const _Broken({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Center(child: Icon(Icons.broken_image_outlined, color: color));
}
