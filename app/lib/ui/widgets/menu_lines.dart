import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import 'artwork.dart';
import 'motion.dart';
import 'sheet_tile.dart';

/// One line of a menu: an icon, the words, and what it does. [apart] sets it at the bottom under a rule, for what the
/// person is least likely to want (not being shown a song again).
class MenuLine {
  const MenuLine(
    this.value,
    this.icon,
    this.label, {
    this.enabled = true,
    this.apart = false,
  });

  final String value;
  final IconData icon;
  final String label;
  final bool enabled;
  final bool apart;
}

/// What a line of a popup menu says: its icon, then the words.
class MenuLabel extends StatelessWidget {
  const MenuLabel(this.icon, this.label, {super.key, this.enabled = true});

  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Icon(icon, size: 20, color: enabled ? p.textSecondary : p.textTertiary),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    );
  }
}

/// The popup items of [lines], each with its icon: for a menu at the touch, where there is room for one.
List<PopupMenuEntry<String>> popupLines(List<MenuLine> lines) => [
  for (final line in lines)
    PopupMenuItem(
      value: line.value,
      enabled: line.enabled,
      child: MenuLabel(line.icon, line.label, enabled: line.enabled),
    ),
];

/// The "…" of a song. On a phone it opens a sheet from the bottom, with the cover, the title and the artist of the song
/// at its head and a line for each thing to do, as the music apps do; where there is room (a tablet on its side, a
/// computer) it is the small menu at the touch, with the same icons. [menuKey] lets a row open the small one from a
/// right click.
class SongMenuButton extends StatelessWidget {
  const SongMenuButton({
    super.key,
    required this.track,
    required this.lines,
    required this.onSelected,
    this.menuKey,
  });

  final Track track;

  /// Made when the menu is opened, not when the button is drawn: what a song can be offered (download, like) changes
  /// under a button that nobody redraws.
  final List<MenuLine> Function() lines;
  final void Function(String value) onSelected;
  final GlobalKey<PopupMenuButtonState<String>>? menuKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final icon = Icon(Icons.more_horiz_rounded, color: p.textSecondary);
    if (HomeShell.layoutOf(context) != ShellLayout.bars) {
      return PopupMenuButton<String>(
        key: menuKey,
        useRootNavigator: true,
        icon: icon,
        color: p.menu,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: onSelected,
        itemBuilder: (context) => popupLines(lines()),
      );
    }
    return IconButton(
      icon: icon,
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        sheetAnimationStyle: Motion.sheet(context),
        builder: (sheet) => _SongSheet(
          track: track,
          lines: lines(),
          onSelected: (value) {
            Navigator.of(sheet).pop();
            onSelected(value);
          },
        ),
      ),
    );
  }
}

class _SongSheet extends StatelessWidget {
  const _SongSheet({
    required this.track,
    required this.lines,
    required this.onSelected,
  });

  final Track track;
  final List<MenuLine> lines;
  final void Function(String value) onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    // The rows are the make of the rows of the room's settings (`SheetTile`), in the same margins, so that the sheets of
    // the app read as one
    Widget row(MenuLine line) => SheetTile(
      key: ValueKey('menu-${line.value}'),
      icon: line.icon,
      title: line.label,
      enabled: line.enabled,
      onTap: () => onSelected(line.value),
    );
    final main = [
      for (final line in lines)
        if (!line.apart) line,
    ];
    final apart = [
      for (final line in lines)
        if (line.apart) line,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Artwork(url: track.thumb, size: 48, radius: 10),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.titleMedium,
                        ),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodySmall?.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            for (final line in main) row(line),
            if (apart.isNotEmpty) ...[
              Divider(height: 17, color: p.outlineSoft),
              for (final line in apart) row(line),
            ],
          ],
        ),
      ),
    );
  }
}
