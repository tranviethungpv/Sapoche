import 'package:flutter/material.dart';

import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

/// Lets the person mix a colour of their own for the app; resolves to it, or null when they close the sheet.
Future<Color?> showAccentPicker(BuildContext context, Color initial) =>
    showModalBottomSheet<Color>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (_) => _AccentPicker(initial: initial),
    );

class _AccentPicker extends StatefulWidget {
  const _AccentPicker({required this.initial});

  final Color initial;

  @override
  State<_AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<_AccentPicker> {
  late HSVColor _color = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final color = _color.toColor();
    // What the app will look like in this colour, in the theme it is in now
    final preview = buildTheme(Palette.forAccent(color, p.brightness));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.accentColor, style: theme.titleLarge),
            const SizedBox(height: 14),
            Theme(
              data: preview,
              child: Builder(
                builder: (context) => _Preview(palette: context.palette),
              ),
            ),
            const SizedBox(height: 18),
            _GradientSlider(
              key: const ValueKey('accent-hue'),
              label: S.accentHue,
              value: _color.hue / 360,
              colors: [
                for (var h = 0; h <= 360; h += 60)
                  HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
              ],
              onChanged: (v) =>
                  setState(() => _color = _color.withHue(v * 360)),
            ),
            _GradientSlider(
              key: const ValueKey('accent-saturation'),
              label: S.accentSaturation,
              value: _color.saturation,
              colors: [
                _color.withSaturation(0).toColor(),
                _color.withSaturation(1).toColor(),
              ],
              onChanged: (v) =>
                  setState(() => _color = _color.withSaturation(v)),
            ),
            _GradientSlider(
              key: const ValueKey('accent-brightness'),
              label: S.accentBrightness,
              value: _color.value,
              colors: [
                _color.withValue(0).toColor(),
                _color.withValue(1).toColor(),
              ],
              onChanged: (v) => setState(() => _color = _color.withValue(v)),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('accent-use'),
                onPressed: () => Navigator.pop(context, color),
                child: Text(S.accentUse),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A button, a switch and a line of words in the palette that the colour makes.
class _Preview extends StatelessWidget {
  const _Preview({required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.washTop, palette.base],
        ),
        borderRadius: BorderRadius.circular(SapocheTheme.groupRadius),
        border: Border.all(color: palette.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.appName, style: theme.titleMedium),
                const SizedBox(height: 2),
                Text(S.accentColor, style: theme.bodySmall),
              ],
            ),
          ),
          Switch(value: true, onChanged: (_) {}),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () {},
            child: const Icon(Icons.play_arrow_rounded),
          ),
        ],
      ),
    );
  }
}

/// A slider whose track shows the colours it goes through, 0 to 1.
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  static const _height = 28.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Semantics(
      label: label,
      value: '${(value * 100).round()}%',
      increasedValue: '${((value + 0.05).clamp(0.0, 1.0) * 100).round()}%',
      decreasedValue: '${((value - 0.05).clamp(0.0, 1.0) * 100).round()}%',
      onIncrease: () => onChanged((value + 0.05).clamp(0.0, 1.0)),
      onDecrease: () => onChanged((value - 0.05).clamp(0.0, 1.0)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.labelMedium),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, box) {
                void set(Offset at) =>
                    onChanged((at.dx / box.maxWidth).clamp(0.0, 1.0));
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => set(d.localPosition),
                  onHorizontalDragStart: (d) => set(d.localPosition),
                  onHorizontalDragUpdate: (d) => set(d.localPosition),
                  child: SizedBox(
                    height: _height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 12,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: colors),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: p.outline),
                          ),
                        ),
                        Positioned(
                          left: value * box.maxWidth - _height / 2,
                          child: Container(
                            width: _height,
                            height: _height,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: p.outline, width: 2),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
