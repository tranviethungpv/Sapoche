import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// Cover image with rounded corners; shows a soft pink tile while loading or when there is none.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.radius = UnisonTheme.artworkRadius,
  });

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final placeholder = ColoredBox(
      color: p.primaryContainer,
      child: Icon(
        Icons.music_note_rounded,
        color: p.primary.withValues(alpha: 0.6),
        size: size * 0.42,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? placeholder
            : Image.network(
                url!,
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => placeholder,
                frameBuilder: (context, child, frame, sync) => sync
                    ? child
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          placeholder,
                          AnimatedOpacity(
                            opacity: frame == null ? 0 : 1,
                            duration: const Duration(milliseconds: 300),
                            child: child,
                          ),
                        ],
                      ),
              ),
      ),
    );
  }
}
