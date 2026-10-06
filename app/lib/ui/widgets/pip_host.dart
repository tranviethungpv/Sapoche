import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import 'video_view.dart';

/// Shows only the picture while the app sits in a small window over other apps. The app itself stays as it was
/// underneath, laid out at the size it had: the small window is no screen for it, and a screen that saw itself turned
/// on its side would act on it (open the picture across a screen that is not there).
class PipHost extends StatefulWidget {
  const PipHost({super.key, required this.controller, required this.child});

  final RoomController controller;
  final Widget child;

  @override
  State<PipHost> createState() => _PipHostState();
}

class _PipHostState extends State<PipHost> {
  /// The screen as it was before the small window, kept while it shows.
  MediaQueryData? _screen;

  /// Smaller than any phone held either way: the small window, or a step on the way to it.
  static const _smallest = 300.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The song too, for its cover until the next one's first frame
    listenable: Listenable.merge([
      widget.controller.pictureInPicture,
      widget.controller,
    ]),
    builder: (context, child) {
      final pip = widget.controller.pictureInPicture.value;
      final media = MediaQuery.of(context);
      if (!pip && media.size.shortestSide >= _smallest) _screen = media;
      final screen = pip ? (_screen ?? media) : media;
      final current = widget.controller.snapshot.current;
      // The same widgets whether the small window shows or not, so that nothing underneath is built anew
      return Stack(
        fit: StackFit.expand,
        children: [
          OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: screen.size.width,
            maxWidth: screen.size.width,
            minHeight: screen.size.height,
            maxHeight: screen.size.height,
            child: MediaQuery(
              data: screen,
              child: TickerMode(
                enabled: !pip,
                child: Offstage(offstage: pip, child: child),
              ),
            ),
          ),
          if (pip)
            current == null
                ? const ColoredBox(color: Colors.black)
                : VideoView(
                    key: const ValueKey('pip-video'),
                    controller: widget.controller,
                    cover: current,
                    fit: BoxFit.contain,
                  ),
        ],
      );
    },
    child: widget.child,
  );
}
