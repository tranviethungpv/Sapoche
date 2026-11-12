import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// One row of a sheet (the room's settings, the menu of a song), the same make for each: an icon, what it is, a line on what it does, and at the end
/// its switch, a chevron, or a [trailing] widget of its own. With [onChanged] the whole row is the switch.
class SheetTile extends StatelessWidget {
  const SheetTile({
    super.key,
    required this.icon,
    required this.title,
    this.help,
    this.value,
    this.onChanged,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
    this.trailing,
    this.below,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? help;

  /// A switch, when there is [onChanged].
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onTap;
  final bool chevron;

  /// Leaving: in the colour of a warning.
  final bool destructive;
  final Widget? trailing;

  /// Under the line of help, for a link.
  final Widget? below;

  /// Dimmed and not to be touched, for what cannot be done now.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final color = destructive
        ? p.error
        : enabled
        ? p.text
        : p.textTertiary;
    final end =
        trailing ??
        (onChanged != null
            ? Switch(value: value ?? false, onChanged: onChanged)
            : chevron
            ? Icon(Icons.chevron_right_rounded, color: p.textTertiary)
            : null);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Icon(
              icon,
              size: 24,
              color: destructive
                  ? p.error
                  : enabled
                  ? p.textSecondary
                  : p.textTertiary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.titleMedium?.copyWith(color: color)),
                if (help != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    help!,
                    style: theme.bodySmall?.copyWith(color: p.textSecondary),
                  ),
                ],
                ?below,
              ],
            ),
          ),
          if (end != null) ...[const SizedBox(width: 12), end],
        ],
      ),
    );
    // A screen reader reads the switch together with what it is for
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: !enabled
            ? null
            : onChanged != null
            ? () => onChanged!(!(value ?? false))
            : onTap,
        child: row,
      ),
    );
  }
}

