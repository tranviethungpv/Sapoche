import 'package:flutter/material.dart';

import 'motion.dart';

/// Gives the app bar of a page the page's name once the top of the page, which holds it in large type, has scrolled
/// out of sight: a page scrolled down to its songs would show nothing but the back button. [builder] makes the page
/// with that title; it is empty (and invisible) until then.
class TitleOnScroll extends StatefulWidget {
  const TitleOnScroll({super.key, required this.title, required this.builder});

  final String title;
  final Widget Function(BuildContext context, Widget title) builder;

  /// How far the page has scrolled when its own title is gone under the bar.
  static const after = 240.0;

  @override
  State<TitleOnScroll> createState() => _TitleOnScrollState();
}

class _TitleOnScrollState extends State<TitleOnScroll> {
  bool _past = false;

  bool _scrolled(ScrollNotification n) {
    // The lists of covers that scroll sideways inside the page are not the page
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      final past = n.metrics.pixels > TitleOnScroll.after;
      if (past != _past) setState(() => _past = past);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scrolled,
        child: widget.builder(
          context,
          AnimatedOpacity(
            opacity: _past ? 1 : 0,
            duration: Motion.of(context, Motion.short),
            // Not drawn until it is wanted, so the name is on the page once, as far as anything that looks for it can tell
            child: _past
                ? Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      );
}
