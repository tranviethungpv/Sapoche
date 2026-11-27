import 'dart:async';

import 'package:flutter/material.dart';

import 'widgets/focus_nav.dart' show firstControlIn;

/// The parts of the home screen that a remote's arrows go between: the bar of tabs, the page, and the player (the
/// card beside the pages, or the small player under them).
enum FocusZone { nav, page, player }

/// Which zone lies next to which, in the way the arrows point; what is not named has nothing beyond it. The shell says
/// it for the layout it is in.
typedef ZoneNeighbours = Map<FocusZone, Map<TraversalDirection, FocusZone>>;

/// Takes the arrows across the parts of the home screen. Flutter keeps the arrows inside the page that has the focus: at
/// its edge they stop, so a remote could never reach the tabs or the player, which stand outside the page. Here an arrow
/// is tried inside the zone first, as Flutter does; at the edge of the zone it goes to the zone that lies that way, and
/// there to the control that had the focus when it was left (and not to whichever lies nearest, which is a guess).
class FocusZones extends ChangeNotifier {
  FocusZones() {
    FocusManager.instance.addListener(_remember);
    FocusManager.instance.addHighlightModeListener(_mode);
  }

  final _nodes = {
    for (final zone in FocusZone.values)
      // A scope, so that the arrows look for the next control inside the zone only: an open rail lies over the page, and a
      // control of the page that is nearer than the next tab would be the one an arrow found
      // (canRequestFocus stays true: for a scope, false would shut every control in it too)
      // Tab still goes on from one zone into the next, as it did before the zones were scopes
      zone: FocusScopeNode(
        debugLabel: 'zone ${zone.name}',
        skipTraversal: true,
        traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
      ),
  };

  /// What had the focus last in each zone.
  final _last = <FocusZone, FocusNode>{};

  /// Which zones lie where: the layout sets it when it is built.
  ZoneNeighbours neighbours = const {};

  @override
  void dispose() {
    FocusManager.instance.removeListener(_remember);
    FocusManager.instance.removeHighlightModeListener(_mode);
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// The node of [zone]: it has the focus while any control of the zone does, and tells so.
  FocusScopeNode nodeOf(FocusZone zone) => _nodes[zone]!;

  /// Draws [child] as the zone [zone].
  Widget zone(FocusZone zone, Widget child) =>
      FocusScope(node: _nodes[zone]!, includeSemantics: false, child: child);

  /// The zone that [node] is in, null for a node outside all of them (a dialog, a sheet).
  FocusZone? zoneOf(FocusNode? node) {
    if (node == null) return null;
    for (final ancestor in node.ancestors) {
      for (final entry in _nodes.entries) {
        if (identical(entry.value, ancestor)) return entry.key;
      }
    }
    return null;
  }

  /// The zone that has the focus, for what asks where Back should go.
  FocusZone? current;

  /// Keys come into use or go out of it: what asks (Back) is told.
  void _mode(FocusHighlightMode _) => notifyListeners();

  void _remember() {
    final node = FocusManager.instance.primaryFocus;
    final zone = zoneOf(node);
    if (zone != null && node != null && node is! FocusScopeNode) {
      _last[zone] = node;
    }
    if (zone != current) {
      current = zone;
      notifyListeners();
    }
  }

  static bool _usable(FocusNode node) =>
      node.canRequestFocus &&
      !node.skipTraversal &&
      (node.context?.mounted ?? false);

  /// The control of [zone] that is nearest its top left corner: where the focus goes into a zone it has not been in.
  FocusNode? _first(FocusZone zone) => _firstIn(_nodes[zone]!);

  FocusNode? _firstIn(FocusScopeNode own) => firstControlIn(own);

  /// Puts the focus into [zone]: on what had it there, or else on its first control. False when it has nothing to give it
  /// to.
  bool enter(FocusZone zone) {
    final before = _last[zone];
    final node = before != null && _usable(before) ? before : _first(zone);
    if (node == null) return false;
    node.requestFocus();
    return true;
  }

  /// The arrow [direction] was pressed: the focus moves inside its zone, or leaves it for the one that lies that way.
  /// False when nothing moved.
  bool move(TraversalDirection direction) {
    if (_justStarted) return true;
    final node = FocusManager.instance.primaryFocus;
    final zone = zoneOf(node);
    if (node == null) return false;
    if (zone == null) return node.focusInDirection(direction);
    if (node.focusInDirection(direction)) {
      // The focus is only asked for so far: it is looked at where it has landed
      FocusManager.instance.applyFocusChangesIfNeeded();
      // Flutter looks through the whole window: the control it found may be in the next zone, which is only fair if
      // that is where the arrow points, and then it is entered as a zone is, by the control that had the focus there
      final to = zoneOf(FocusManager.instance.primaryFocus);
      if (to == zone) return true;
      node.requestFocus();
    }
    final next = neighbours[zone]?[direction];
    return next != null && enter(next);
  }

  /// The first press of a key, with nothing in the zones that has the focus yet: the page gets it.
  bool start() {
    final node = FocusManager.instance.primaryFocus;
    // A page's own scope has the focus when no control has it yet: that is nothing, as far as the arrows are concerned
    // A page opened over the first one has the focus on its own scope: its first control, not what is under it
    if (node is FocusScopeNode && zoneOf(node) != null) {
      final first = _firstIn(node);
      if (first != null) {
        first.requestFocus();
        _justStarted = true;
        scheduleMicrotask(() => _justStarted = false);
        return true;
      }
    }
    final nothing =
        node == null || node is FocusScopeNode || zoneOf(node) == null;
    if (!(nothing && enter(FocusZone.page))) return false;
    // The same press is also on its way to the focus tree, which would move the focus on from where it was just put
    _justStarted = true;
    scheduleMicrotask(() => _justStarted = false);
    return true;
  }

  bool _justStarted = false;

  /// What the page remembered is of the page that was shown: a tab was changed.
  void forgetPage() => _last.remove(FocusZone.page);
}

/// Gives the arrow keys to [zones]. Under it, an arrow that nothing in a zone takes moves the focus as Flutter does.
class ZoneArrows extends StatelessWidget {
  const ZoneArrows({super.key, required this.zones, required this.child});

  final FocusZones zones;
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
        onInvoke: (intent) => zones.move(intent.direction),
      ),
    },
    child: child,
  );
}
