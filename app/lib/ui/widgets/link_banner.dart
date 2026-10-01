import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import 'glass.dart';

/// A small pill that slides in when the connection to the room is not healthy.
class LinkBanner extends StatelessWidget {
  const LinkBanner({super.key, required this.link});

  final Link link;

  String? get _text => switch (link) {
    Link.connecting => S.connecting,
    Link.reconnecting => S.reconnecting,
    Link.closed => S.offline,
    Link.unauthorized => S.unauthorized,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = _text;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Container(
              key: ValueKey(text),
              margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: GlassDecoration.of(
                p,
                radius: 999,
                tint: p.primaryContainer,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (link != Link.unauthorized && link != Link.closed)
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.onPrimaryContainer,
                      ),
                    )
                  else
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: p.onPrimaryContainer,
                    ),
                  const SizedBox(width: 10),
                  Text(
                    text,
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: p.onPrimaryContainer),
                  ),
                ],
              ),
            ),
    );
  }
}
