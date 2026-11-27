import 'package:flutter/material.dart';

import '../../data/connect/connect_wire.dart' show DeviceKind;
import '../../strings.dart';
import '../../theme/theme.dart';
import '../connect_ui.dart';
import '../focus_zones.dart';
import '../home_shell.dart';
import '../player_sheet.dart';
import '../scope.dart';
import '../settings_page.dart';
import '../widgets/glass.dart';
import '../widgets/motion.dart';

/// The tabs of a TV: a column of icons at the left edge that opens to a column with their names while the focus is in it,
/// over the page and not pushing it, as the drawers of the TV apps do. A remote's left arrow reaches it from the page.
class TvRail extends StatelessWidget {
  const TvRail({
    super.key,
    required this.index,
    required this.onSelect,
    required this.zones,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final FocusZones zones;

  /// The width it keeps, and the width it opens to.
  static const width = 72.0;
  static const openWidth = 248.0;

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    final listen = HomeShell.listenLabelOf(context);
    return AnimatedBuilder(
      // The focus node of the zone says whether the focus is anywhere in the column
      animation: zones.nodeOf(FocusZone.nav),
      builder: (context, _) {
        final open = zones.nodeOf(FocusZone.nav).hasFocus;
        Widget item(
          IconData icon,
          String label,
          bool selected,
          VoidCallback onTap,
        ) => _TvRailItem(
          icon: icon,
          label: label,
          selected: selected,
          open: open,
          onTap: onTap,
        );
        // Wider than the room it is given when it is open: it lies over the page
        return OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: openWidth,
          child: AnimatedContainer(
            duration: Motion.of(context, 180),
            curve: Curves.easeOutCubic,
            width: open ? openWidth : width,
            child: Glass(
              borderRadius: BorderRadius.circular(width / 2),
              child: ListenableBuilder(
                listenable: room,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    children: [
                      item(
                        Icons.home_rounded,
                        S.tabHome,
                        index == 0,
                        () => onSelect(0),
                      ),
                      item(
                        Icons.search_rounded,
                        S.tabSearch,
                        index == 1,
                        () => onSelect(1),
                      ),
                      item(
                        Icons.library_music_rounded,
                        S.tabLibrary,
                        index == 2,
                        () => onSelect(2),
                      ),
                      item(
                        Icons.graphic_eq_rounded,
                        listen,
                        index == 3,
                        () => onSelect(3),
                      ),
                      // The player is the screen of a song: on a TV there is nothing beside the pages to show it
                      if (room.snapshot.current != null)
                        () {
                          // Another device of the person plays: the rail says which, and the player steers it
                          final other = controllingAnother(context) ? connectOf(context)?.activeDevice : null;
                          return item(
                            other == null ? Icons.music_note_rounded : deviceIcon(other.info?.kind ?? DeviceKind.phone),
                            other?.info?.name ?? S.nowPlaying,
                            false,
                            sheet.open,
                          );
                        }(),
                      const Spacer(),
                      item(
                        Icons.settings_outlined,
                        S.settingsTitle,
                        false,
                        () => openSettings(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TvRailItem extends StatelessWidget {
  const _TvRailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = selected ? p.primary : p.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? p.veilStrong : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: Semantics(
          selected: selected,
          child: Tooltip(
            message: label,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Icon(icon, size: 28, color: color),
                    ),
                    if (open)
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(color: color),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
