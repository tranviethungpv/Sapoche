import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/theme.dart';
import '../scope.dart';

/// Soft pastel tints that sit well on a pink background, picked per person from their name.
const _tints = [
  Color(0xFFF4B6C6),
  Color(0xFFE8B9D9),
  Color(0xFFF6C7B3),
  Color(0xFFD5B8E8),
  Color(0xFFF2D0A9),
  Color(0xFFB9CFE8),
];

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.size = 36,
    this.ring = false,
    this.image,
  });

  final String name;
  final double size;

  /// The person's own picture, if they chose one; it takes the place of the initial.
  final Uint8List? image;

  /// A thin ring in the background colour, so overlapping avatars stay distinct.
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tint =
        _tints[name.runes.fold<int>(0, (a, b) => a + b) % _tints.length];
    final dark = p.brightness == Brightness.dark;
    final initial = name.trim().isEmpty
        ? '?'
        : String.fromCharCode(name.trim().runes.first).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dark ? Color.lerp(tint, p.base, 0.55) : tint,
        border: ring ? Border.all(color: p.base, width: 2) : null,
        image: image == null
            ? null
            : DecorationImage(image: MemoryImage(image!), fit: BoxFit.cover),
      ),
      child: image != null
          ? null
          : Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                color: dark ? const Color(0xFFFFE8EF) : const Color(0xFF5A2A3A),
              ),
            ),
    );
  }
}

/// Overlapping avatars of everyone in the room.
class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.members,
    this.size = 32,
    this.max = 5,
  });

  final List<Member> members;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return ListenableBuilder(
      listenable: model.settings,
      builder: (context, _) =>
          _stack(context, model.settings.avatar, model.room.snapshot.you),
    );
  }

  Widget _stack(BuildContext context, Uint8List? mine, String? you) {
    final shown = members.take(max).toList();
    final extra = members.length - shown.length;
    final step = size * 0.68;
    return SizedBox(
      height: size,
      width: step * (shown.length + (extra > 0 ? 1 : 0)) + size - step,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              key: ValueKey(shown[i].id),
              left: step * i,
              child: _PopIn(
                child: Avatar(
                  name: shown[i].name,
                  size: size,
                  ring: true,
                  image: shown[i].id == you ? mine : null,
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: step * shown.length,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.palette.primaryContainer,
                  border: Border.all(color: context.palette.base, width: 2),
                ),
                child: Text(
                  '+$extra',
                  style: TextStyle(
                    fontSize: size * 0.36,
                    fontWeight: FontWeight.w700,
                    color: context.palette.onPrimaryContainer,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Scales in with a small overshoot when first built: someone just joined.
class _PopIn extends StatelessWidget {
  const _PopIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.5, end: 1),
    duration: const Duration(milliseconds: 450),
    curve: Curves.easeOutBack,
    builder: (context, scale, child) =>
        Transform.scale(scale: scale, child: child),
    child: child,
  );
}
