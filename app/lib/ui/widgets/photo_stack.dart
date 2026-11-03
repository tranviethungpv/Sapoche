import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../data/calm.dart';
import '../../data/chat_media.dart';
import '../../strings.dart';
import 'album_image.dart';
import 'on_screen.dart';

/// The place on screen of what [context] draws, for a page to grow out of.
Rect? screenRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Whether a picture of the chat may move: not when the system or the app wants calm, and not once it is out of sight.
bool _mayPlay(BuildContext context, bool visible, AlbumSlot slot) =>
    visible && slot.animated && !MediaQuery.disableAnimationsOf(context) && !Calm.on.value;

/// A single picture in the chat, with no bubble: as wide as the picture's shape allows, rounded.
class SinglePhoto extends StatelessWidget {
  const SinglePhoto({
    super.key,
    required this.slot,
    required this.media,
    required this.room,
    required this.onTap,
    this.overlay,
    this.badge,
  });

  final AlbumSlot slot;
  final ChatMedia media;
  final String room;

  /// Told the place of the picture on screen.
  final ValueChanged<Rect?> onTap;

  /// Drawn over the picture (how far it has gone up, that it failed).
  final Widget? overlay;

  /// Drawn over the picture, under [overlay] (the play mark of a video).
  final Widget? badge;

  static const maxHeight = 270.0;

  @override
  Widget build(BuildContext context) {
    var width = MediaQuery.sizeOf(context).width * 0.6;
    var height = width / slot.aspect;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * slot.aspect;
    }
    return GestureDetector(
      key: const ValueKey('photo-single'),
      onTap: () => onTap(screenRectOf(context)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              OnScreen(
                builder: (context, visible) => AlbumImage(
                  slot: slot,
                  media: media,
                  room: room,
                  cacheWidth: 720,
                  playing: _mayPlay(context, visible, slot),
                ),
              ),
              ?badge,
              ?overlay,
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a card behind the top one goes, as the stack opens.
class _Back {
  const _Back(this.angle, this.dx, this.scale, this.dark);

  /// Radians.
  final double angle;
  final double dx;
  final double scale;

  /// How much black is laid over the card, 0 to 1.
  final double dark;
}

/// Two to ten pictures as a stack of photos, the way Messenger shows an album: the first one on top, the next two
/// fanned out from behind it, all in a square, and the number of pictures at its corner. A new one fans out; a touch
/// presses it.
class PhotoStack extends StatefulWidget {
  const PhotoStack({
    super.key,
    required this.slots,
    required this.media,
    required this.room,
    required this.fresh,
    required this.onTap,
    this.overlay,
  });

  final List<AlbumSlot> slots;
  final ChatMedia media;
  final String room;

  /// The message has just arrived, so the cards fan out from under the top one.
  final bool fresh;

  /// Told the place of the top card on screen.
  final ValueChanged<Rect?> onTap;

  /// Drawn over the top card (how far the pictures have gone up, that one failed).
  final Widget? overlay;

  @override
  State<PhotoStack> createState() => _PhotoStackState();
}

class _PhotoStackState extends State<PhotoStack> with TickerProviderStateMixin {
  static const _radius = 16.0;
  static const _side = 174.0; // the top card is a square, no wider than this
  static const _room = 27.0; // what the cards behind reach out sideways

  /// Left and right behind the top card; the angles get a degree or so of their own from the picture's id.
  static final _backs = [_Back(-8 * pi / 180, -16.5, 0.94, 0.08), _Back(7 * pi / 180, 16.5, 0.90, 0.14)];

  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.6);

  /// 0 with the cards under the top one, 1 spread out; the spring overshoots it a little.
  late final AnimationController _fan = AnimationController.unbounded(value: 1, vsync: this);

  /// 0 at rest, 1 under a finger.
  late final AnimationController _press = AnimationController.unbounded(value: 0, vsync: this);

  bool _started = false;
  bool _pressing = false;
  Offset _downAt = Offset.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.fresh || MediaQuery.disableAnimationsOf(context)) return;
    _fan.value = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fan.animateWith(SpringSimulation(_spring, 0, 1, 0));
    });
  }

  @override
  void dispose() {
    _fan.dispose();
    _press.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    _pressing = true;
    _downAt = event.position;
    _press.animateTo(1, duration: const Duration(milliseconds: 90), curve: Curves.easeOut);
  }

  void _moved(PointerMoveEvent event) {
    // A drag is the reply gesture: the stack lets go
    if (_pressing && (event.position - _downAt).distance > 12) _release();
  }

  void _release() {
    if (!_pressing) return;
    _pressing = false;
    _press.animateWith(SpringSimulation(_spring, _press.value, 0, 0));
  }

  /// A degree or so either way that stays the same for the same picture, so a stack looks the same every time it is drawn.
  double _tilt(AlbumSlot slot) {
    var hash = 0x811c9dc5;
    for (final unit in slot.id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return ((hash % 21) - 10) * 0.1 * pi / 180;
  }

  Widget _backCard(int k, double width, double height, double spread) {
    final back = _backs[k];
    final slot = widget.slots[k + 1];
    final scale = 1 + (back.scale - 1) * spread;
    return Transform(
      key: ValueKey('photo-stack-back-$k'),
      alignment: Alignment.center,
      transform: Matrix4.translationValues(back.dx * spread, 0, 0)
        ..rotateZ((back.angle + _tilt(slot) * back.angle.sign) * spread)
        ..scaleByDouble(scale, scale, 1, 1),
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AlbumImage(slot: slot, media: widget.media, room: widget.room, cacheWidth: 360),
              ColoredBox(color: Colors.black.withValues(alpha: (back.dark * spread).clamp(0.0, 1.0))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topCard(double width, double height) {
    final slot = widget.slots.first;
    return SizedBox(
      key: const ValueKey('photo-stack-top'),
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              OnScreen(
                builder: (context, visible) => AlbumImage(
                  slot: slot,
                  media: widget.media,
                  room: widget.room,
                  cacheWidth: 540,
                  playing: _mayPlay(context, visible, slot),
                ),
              ),
              Positioned(right: 8, bottom: 8, child: _Count(widget.slots)),
              ?widget.overlay,
            ],
          ),
        ),
      ),
    );
  }

  Widget _layout(double width, double height, double fan, double press) {
    // Under a finger the cards behind close in and the stack shrinks a little
    final spread = fan * (1 - 0.5 * press);
    final scale = 1 - 0.03 * press;
    return Transform.scale(
      scale: scale,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          for (var k = min(_backs.length, widget.slots.length - 1) - 1; k >= 0; k--)
            _backCard(k, width, height, spread),
          _topCard(width, height),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final width = min(_side, MediaQuery.sizeOf(context).width * 0.6);
    final height = width;
    return Semantics(
      button: true,
      label: S.photoCount(widget.slots.length),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: still ? null : _down,
        onPointerMove: still ? null : _moved,
        onPointerUp: still ? null : (_) => _release(),
        onPointerCancel: still ? null : (_) => _release(),
        child: GestureDetector(
          key: const ValueKey('photo-stack'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onTap(_topRect(context, width, height)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _room, vertical: 12),
            child: still
                ? _layout(width, height, 1, 0)
                : AnimatedBuilder(
                    animation: Listenable.merge([_fan, _press]),
                    builder: (context, _) => _layout(width, height, _fan.value, _press.value),
                  ),
          ),
        ),
      ),
    );
  }

  /// The top card's place on screen, which the page that opens grows out of.
  Rect? _topRect(BuildContext context, double width, double height) {
    final all = screenRectOf(context);
    return all == null ? null : Rect.fromCenter(center: all.center, width: width, height: height);
  }
}

/// At the corner of the top card: the number of pictures, and GIF where one of them moves.
class _Count extends StatelessWidget {
  const _Count(this.slots);

  final List<AlbumSlot> slots;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700);
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(11)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 13, color: Colors.white),
            const SizedBox(width: 4),
            Text('${slots.length}', key: const ValueKey('photo-stack-count'), style: style),
            if (slots.any((s) => s.animated)) ...[
              const SizedBox(width: 4),
              Text('GIF', key: const ValueKey('photo-stack-gif'), style: style),
            ],
          ],
        ),
      ),
    );
  }
}
