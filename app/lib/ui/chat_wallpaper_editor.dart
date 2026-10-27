import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/chat_theme.dart';
import '../data/photo_picker.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'chat_look.dart';

/// A photo placed in the frame of the chat, and the theme made of its colours.
class WallpaperChoice {
  const WallpaperChoice(this.picture, this.theme);

  /// What goes behind the chat: the part of the photo inside the frame, small enough for the room.
  final Uint8List picture;
  final ChatTheme theme;
}

/// The shape of the frame: a phone standing up. A chat on a wider screen shows the middle of the picture.
const wallpaperFrameAspect = 9 / 16;

/// Lets the person place [photo] in the frame of the chat, with the colours of the theme already blended over it and
/// a few messages on it, as the chat will look. Gives back what they chose, or null when they back out.
Future<WallpaperChoice?> showWallpaperEditor(
  BuildContext context,
  Uint8List photo,
) => Navigator.of(context, rootNavigator: true).push<WallpaperChoice>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => WallpaperEditor(photo: photo),
  ),
);

class WallpaperEditor extends StatefulWidget {
  const WallpaperEditor({super.key, required this.photo});

  /// An upright picture, as `uprightPhoto` makes it.
  final Uint8List photo;

  @override
  State<WallpaperEditor> createState() => _WallpaperEditorState();
}

class _WallpaperEditorState extends State<WallpaperEditor> {
  static const _maxZoom = 4.0;

  Size? _size;
  ChatTheme? _theme;

  /// Reading the photo is over, with or without success.
  bool _loaded = false;

  /// The frame as the last layout made it.
  Size _frame = Size.zero;

  /// How many times the photo is blown up beyond just filling the frame, 1 to [_maxZoom].
  double _zoom = 1;

  /// The point of the photo in the middle of the frame, as fractions of its width and height.
  Offset _center = const Offset(0.5, 0.5);
  bool _blended = true;
  bool _saving = false;

  // At the start of a gesture
  double _zoomAtStart = 1;
  Offset _centerAtStart = Offset.zero;
  Offset _focalAtStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final photo = widget.photo;
    final image = await _decode(photo);
    final theme = await ChatTheme.fromPhoto(photo);
    if (!mounted) return;
    setState(() {
      _size = image == null
          ? null
          : Size(image.width.toDouble(), image.height.toDouble());
      _theme = theme;
      _loaded = true;
    });
    image?.dispose();
  }

  Future<ui.Image?> _decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// The photo at the scale that just covers a frame of [frame], times the zoom.
  double _scale(Size frame) {
    final size = _size!;
    return max(frame.width / size.width, frame.height / size.height) * _zoom;
  }

  /// [center] moved the least that keeps the frame inside the photo.
  Offset _kept(Offset center, Size frame) {
    final size = _size!;
    final scale = _scale(frame);
    final halfW = frame.width / scale / size.width / 2;
    final halfH = frame.height / scale / size.height / 2;
    return Offset(
      center.dx.clamp(halfW, 1 - halfW),
      center.dy.clamp(halfH, 1 - halfH),
    );
  }

  void _start(ScaleStartDetails d) {
    _zoomAtStart = _zoom;
    _centerAtStart = _center;
    _focalAtStart = d.focalPoint;
  }

  void _update(ScaleUpdateDetails d, Size frame) {
    final size = _size!;
    setState(() {
      _zoom = (_zoomAtStart * d.scale).clamp(1.0, _maxZoom);
      final scale = _scale(frame);
      final moved = d.focalPoint - _focalAtStart;
      _center = _kept(
        _centerAtStart -
            Offset(
              moved.dx / scale / size.width,
              moved.dy / scale / size.height,
            ),
        frame,
      );
    });
  }

  Future<void> _use() async {
    final frame = _frame;
    final size = _size!;
    final scale = _scale(frame);
    final width = frame.width / scale / size.width;
    final height = frame.height / scale / size.height;
    setState(() => _saving = true);
    final cut = await cutWallpaperAway(
      widget.photo,
      left: _center.dx - width / 2,
      top: _center.dy - height / 2,
      width: width,
      height: height,
    );
    final theme = cut == null ? null : await ChatTheme.fromPhoto(cut);
    if (!mounted) return;
    if (cut == null || theme == null) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.chatThemeUnreadable)));
      return;
    }
    Navigator.of(context).pop(WallpaperChoice(cut, theme));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final ready = _size != null && _theme != null;
    return Scaffold(
      backgroundColor: p.base,
      appBar: AppBar(
        backgroundColor: p.base,
        scrolledUnderElevation: 0,
        leading: IconButton(
          key: const ValueKey('wallpaper-cancel'),
          tooltip: S.cancel,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
        title: Text(S.wallpaperTitle),
        actions: [
          IconButton(
            key: const ValueKey('wallpaper-blend'),
            tooltip: _blended ? S.wallpaperShowPhoto : S.wallpaperShowBlend,
            isSelected: !_blended,
            onPressed: ready
                ? () => setState(() => _blended = !_blended)
                : null,
            icon: const Icon(Icons.blur_on_rounded),
            selectedIcon: const Icon(Icons.photo_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('wallpaper-use'),
              onPressed: ready && !_saving ? _use : null,
              child: Text(S.wallpaperUse),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: !ready
            ? Center(
                child: _loaded
                    ? Text(S.chatThemeUnreadable, style: text.bodyLarge)
                    : const CircularProgressIndicator(),
              )
            : LayoutBuilder(
                builder: (context, box) {
                  final frame = _frame = _frameIn(box.biggest);
                  return Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: _Frame(
                            size: frame,
                            photo: widget.photo,
                            photoSize: _size!,
                            scale: _scale(frame),
                            center: _center,
                            theme: _theme!,
                            blended: _blended,
                            onStart: _start,
                            onUpdate: (d) => _update(d, frame),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                        child: Row(
                          children: [
                            Icon(Icons.zoom_out_rounded, color: p.textTertiary),
                            Expanded(
                              child: Slider(
                                key: const ValueKey('wallpaper-zoom'),
                                value: _zoom,
                                min: 1,
                                max: _maxZoom,
                                onChanged: (v) => setState(() {
                                  _zoom = v;
                                  _center = _kept(_center, frame);
                                }),
                              ),
                            ),
                            Icon(Icons.zoom_in_rounded, color: p.textTertiary),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: Text(
                          _saving ? S.wallpaperSaving : S.wallpaperHint,
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// The largest frame of the shape of the chat that fits in [area], less the room for the slider and the hint.
  Size _frameIn(Size area) {
    final height = max(1.0, area.height - 120);
    final width = min(area.width - 32, height * wallpaperFrameAspect);
    return Size(width, width / wallpaperFrameAspect);
  }
}

/// The photo in its place in the frame, under the blend, with the messages a chat has.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.size,
    required this.photo,
    required this.photoSize,
    required this.scale,
    required this.center,
    required this.theme,
    required this.blended,
    required this.onStart,
    required this.onUpdate,
  });

  final Size size;
  final Uint8List photo;
  final Size photoSize;
  final double scale;
  final Offset center;
  final ChatTheme theme;
  final bool blended;
  final GestureScaleStartCallback onStart;
  final GestureScaleUpdateCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final look = ChatLook.of(theme.id, p);
    final sheet = Theme.of(context).bottomSheetTheme.backgroundColor ?? p.base;
    final width = photoSize.width * scale;
    final height = photoSize.height * scale;
    return GestureDetector(
      key: const ValueKey('wallpaper-frame'),
      onScaleStart: onStart,
      onScaleUpdate: onUpdate,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        child: SizedBox.fromSize(
          size: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: size.width / 2 - center.dx * width,
                top: size.height / 2 - center.dy * height,
                width: width,
                height: height,
                child: Image.memory(
                  photo,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              if (blended && look != null) ...[
                for (final veil in look.veils(sheet))
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: veil),
                    ),
                  ),
                IgnorePointer(child: _Sample(look: look)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A few messages as the chat would show them, to judge the blend by.
class _Sample extends StatelessWidget {
  const _Sample({required this.look});

  final ChatLook look;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    Widget bubble(String words, {required bool mine}) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? null : look.theirs,
          gradient: mine ? look.mine : null,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          words,
          style: text.bodyMedium?.copyWith(color: mine ? look.mineInk : p.text),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          bubble(S.wallpaperSample1, mine: false),
          bubble(S.wallpaperSample2, mine: true),
          bubble(S.wallpaperSample3, mine: false),
        ],
      ),
    );
  }
}
