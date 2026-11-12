import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
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

/// The popup items of [lines], each with its icon: for a menu at the touch, where there is room for one. With [head], the
/// song the menu is about comes first, as at the head of the sheet of a phone.
List<PopupMenuEntry<String>> popupLines(List<MenuLine> lines, {Track? head}) =>
    [
      if (head != null) _SongHead(head),
      for (final line in lines)
        PopupMenuItem(
          value: line.value,
          enabled: line.enabled,
          child: MenuLabel(line.icon, line.label, enabled: line.enabled),
        ),
    ];

/// The song a popup menu is about: its cover, title and artist, above the lines, like the head of a sheet. It cannot be chosen.
class _SongHead extends PopupMenuEntry<String> {
  const _SongHead(this.track);

  final Track track;

  /// What the menu adds to its height for it: the row and the rule under it.
  static const heightOf = 64.0 + 1;

  @override
  double get height => heightOf;

  @override
  bool represents(String? value) => false;

  @override
  State<_SongHead> createState() => _SongHeadState();
}

class _SongHeadState extends State<_SongHead> {
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Artwork(url: widget.track.thumb, size: 40, radius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.titleSmall,
                      ),
                      Text(
                        widget.track.artist,
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
        ),
        Divider(height: 1, color: p.outlineSoft),
      ],
    );
  }
}

/// Where a popup menu of [lines] lines (and a head, if [head]) opens from the button of [button]: under it, as a popup
/// does, unless that would reach the floating player at the foot of a wide window, and then above it. The popup's own
/// fitting only keeps it on the screen, and the player is drawn on the screen, over the page.
RelativeRect Function(BuildContext, BoxConstraints) popupAbovePlayer(
  BuildContext button, {
  required int lines,
  bool head = false,
}) => (route, constraints) {
  final box = button.findRenderObject() as RenderBox;
  final size = constraints.biggest;
  final at = box.localToGlobal(Offset.zero) & box.size;
  // A popup menu is padded 8 dp above and below its lines, and its lines are as tall as a thing to tap
  final height =
      16 + lines * kMinInteractiveDimension + (head ? _SongHead.heightOf : 0);
  final floor = size.height - HomeShell.bottomInsetOf(button);
  var top = at.top;
  if (top + height > floor) {
    // Flipped: its foot on the button's head, and never below the floor
    top = math.min(at.top, floor) - height;
    if (top < 8) top = (floor - height).clamp(8.0, size.height);
  }
  return RelativeRect.fromRect(
    Rect.fromLTWH(at.left, top, at.width, at.height),
    Offset.zero & size,
  );
};

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
  final SongMenuHandle? menuKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final icon = Icon(Icons.more_horiz_rounded, color: p.textSecondary);
    if (HomeShell.layoutOf(context) != ShellLayout.bars) {
      return _SongPopup(
        track: track,
        lines: lines,
        onSelected: onSelected,
        handle: menuKey,
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

/// What a row holds to open the menu of its "…" from a right click: the menu puts its way of opening in it.
class SongMenuHandle {
  VoidCallback? open;
}

/// The "…" of a song where the menu is a popup: opened by the button, or by [handle] from a right click.
class _SongPopup extends StatefulWidget {
  const _SongPopup({
    required this.track,
    required this.lines,
    required this.onSelected,
    required this.handle,
  });

  final Track track;
  final List<MenuLine> Function() lines;
  final void Function(String value) onSelected;
  final SongMenuHandle? handle;

  @override
  State<_SongPopup> createState() => _SongPopupState();
}

class _SongPopupState extends State<_SongPopup> {
  @override
  void initState() {
    super.initState();
    widget.handle?.open = _open;
  }

  @override
  void didUpdateWidget(_SongPopup old) {
    super.didUpdateWidget(old);
    if (old.handle != widget.handle) {
      if (identical(old.handle?.open, _open)) old.handle?.open = null;
      widget.handle?.open = _open;
    }
  }

  @override
  void dispose() {
    if (identical(widget.handle?.open, _open)) widget.handle?.open = null;
    super.dispose();
  }

  Future<void> _open() async {
    final made = widget.lines();
    if (made.isEmpty) return;
    final p = context.palette;
    final value = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      color: p.menu,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: popupLines(made, head: widget.track),
      positionBuilder: popupAbovePlayer(
        context,
        lines: made.length,
        head: true,
      ),
    );
    if (value != null && mounted) widget.onSelected(value);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(Icons.more_horiz_rounded, color: context.palette.textSecondary),
    tooltip: MaterialLocalizations.of(context).showMenuTooltip,
    onPressed: _open,
  );
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
  Widget build(BuildContext context) => ActionSheet(
    head: SheetHead(
      leading: Artwork(url: track.thumb, size: 48, radius: 10),
      title: track.title,
      subtitle: track.artist,
    ),
    lines: lines,
    onSelected: onSelected,
  );
}

/// The head of a sheet of actions: what they are about, as a cover, a name and a line under it.
class SheetHead extends StatelessWidget {
  const SheetHead({super.key, required this.leading, required this.title, this.subtitle});

  final Widget leading;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.titleMedium,
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall?.copyWith(color: p.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The sheet of a phone's menu: a [head] on what it is about, then a line for each thing to do, in the make of the rows of
/// the room's settings (`SheetTile`) so that the sheets of the app read as one.
class ActionSheet extends StatelessWidget {
  const ActionSheet({super.key, this.head, required this.lines, required this.onSelected});

  final Widget? head;
  final List<MenuLine> lines;
  final void Function(String value) onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
            ?head,
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

/// The "…" of a page (an album, a playlist) or of a row of a list: on a phone it opens a sheet from the bottom, with
/// [head] at its top, like the "…" of a song; where there is room it is the small menu, which keeps clear of the player
/// bar. [icon] takes the place of the three dots (a spinner while the page is working).
class MoreMenuButton extends StatelessWidget {
  const MoreMenuButton({
    super.key,
    required this.lines,
    required this.onSelected,
    this.head,
    this.icon,
    this.style,
    this.iconColor,
    this.tooltip,
  });

  final List<MenuLine> lines;
  final void Function(String value) onSelected;
  final Widget? head;
  final Widget? icon;
  final ButtonStyle? style;
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final dots = icon ?? Icon(Icons.more_horiz_rounded, color: iconColor);
    final label = tooltip ?? S.showMore;
    if (HomeShell.layoutOf(context) == ShellLayout.bars) {
      return IconButton(
        icon: dots,
        tooltip: label,
        style: style,
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          sheetAnimationStyle: Motion.sheet(context),
          builder: (sheet) => ActionSheet(
            head: head,
            lines: lines,
            onSelected: (value) {
              Navigator.of(sheet).pop();
              onSelected(value);
            },
          ),
        ),
      );
    }
    return Builder(
      builder: (button) => IconButton(
        icon: dots,
        tooltip: label,
        style: style,
        onPressed: () async {
          final p = button.palette;
          final value = await showMenu<String>(
            context: button,
            useRootNavigator: true,
            color: p.menu,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            items: popupLines(lines),
            positionBuilder: popupAbovePlayer(button, lines: lines.length),
          );
          if (value != null && button.mounted) onSelected(value);
        },
      ),
    );
  }
}
