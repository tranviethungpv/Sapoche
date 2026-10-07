import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';

/// The volume of the device, between a quiet and a loud speaker, as in Apple Music. It follows the buttons of the phone
/// and grows under the finger like the seek bar above it.
class VolumeBar extends StatefulWidget {
  const VolumeBar({super.key, required this.controller});

  final RoomController controller;

  @override
  State<VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<VolumeBar> {
  bool _dragging = false;

  void _set(double dx, double width) {
    widget.controller.setVolume((dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget speaker(IconData icon) =>
        Icon(icon, size: 20, color: p.textSecondary);
    return Semantics(
      label: S.volume,
      slider: true,
      child: Row(
        children: [
          speaker(Icons.volume_mute_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  setState(() => _dragging = true);
                  _set(d.localPosition.dx, box.maxWidth);
                },
                onHorizontalDragUpdate: (d) =>
                    _set(d.localPosition.dx, box.maxWidth),
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () => setState(() => _dragging = false),
                onTapUp: (d) => _set(d.localPosition.dx, box.maxWidth),
                child: SizedBox(
                  height: 32,
                  child: Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: widget.controller.volume,
                      builder: (context, level, _) =>
                          TweenAnimationBuilder<double>(
                            tween: Tween(end: _dragging ? 10 : 5),
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOut,
                            builder: (context, height, _) => ClipRRect(
                              borderRadius: BorderRadius.circular(height),
                              child: Stack(
                                children: [
                                  Container(height: height, color: p.outline),
                                  FractionallySizedBox(
                                    widthFactor: level,
                                    child: Container(
                                      height: height,
                                      color: _dragging
                                          ? p.primary
                                          : p.primary.withValues(alpha: 0.9),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          speaker(Icons.volume_up_rounded),
        ],
      ),
    );
  }
}
