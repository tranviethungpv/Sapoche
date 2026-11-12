import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/like_button.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';

/// The machine eye of `docs/plans/2026-11-12-ui-fixed-yardstick.md` (K1): reads a screen the camera has drawn and lists
/// what is wrong with it, so that "contrast", "tap size", "overflow", "overlap", "cut with room to spare" are a list of
/// lines and not an opinion. Each line is `rule: what`.

/// What the app's own `FlutterError`s said while the screen was built, taken here because a layout overflow is reported
/// as an error and would fail the test, not be listed.
class ErrorCatcher {
  final overflows = <String>[];
  final others = <String>[];
  void Function(FlutterErrorDetails)? _before;

  void start() {
    _before = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString(minLevel: DiagnosticLevel.info);
      if (text.contains('overflowed')) {
        // And the widget that overflowed, which the report names a few lines down
        final at = RegExp(r'error-causing widget was:\s*\n\s*(.+)').firstMatch(text);
        final what = text.split('\n').firstWhere((l) => l.contains('overflowed'), orElse: () => 'overflowed').trim();
        overflows.add('$what${at == null ? '' : ' in ${at.group(1)!.trim()}'}');
      } else {
        others.add(text.split('\n').first.trim());
      }
    };
  }

  void stop() => FlutterError.onError = _before;
}

class _Para {
  _Para(
    this.box,
    this.text,
    this.cut,
    this.route, {
    this.inBar = false,
    this.boxed = false,
    this.partly = false,
  });

  final Rect box;
  final String text;
  final bool cut;

  /// The page or sheet the words are on: words of a sheet lie over the page by design and are not "on top of" it.
  final Object? route;

  /// In the player bar of a wide window. Exception of the rule "cut with room", named: the row of its buttons is a
  /// column of its own, centred, so the first thing to the right of the song's name is the skip button, a column's
  /// padding away; the name has had all the room the columns left.
  final bool inBar;

  /// In a place whose edge is its own and not the window's: a card of a shelf that scrolls sideways, a popup menu. Room
  /// to the right of such a name is outside its box, so "cut with room" does not apply. Exception of the rule, named.
  final bool boxed;

  /// Scrolled half out of its list: what is beside it (a button centred on the row) is not on the same lines as the part
  /// that shows, so "room beside it" cannot be read.
  final bool partly;
}

/// Whether something is built but not shown: on a page under another, in a tab that is not the one in front, faded out.
bool _hidden(RenderObject o) {
  RenderObject? child = o;
  for (var up = o.parent; up != null; child = up, up = up.parent) {
    if (up is RenderOffstage && up.offstage) return true;
    if (up is RenderOpacity && up.opacity == 0) return true;
    if (up is RenderAnimatedOpacity && up.opacity.value == 0) return true;
    if (up is RenderIndexedStack && up.index != null) {
      final shown = up.firstChild;
      var at = shown;
      for (var i = 0; at != null && i < up.index!; i++) {
        at =
            (at.parentData! as ContainerParentDataMixin<RenderBox>).nextSibling;
      }
      if (!identical(at, child)) return true;
    }
  }
  return false;
}

/// Where a box is on the screen, with every scale and shift on the way (a `FittedBox` shrinks its text).
Rect _globalBox(RenderBox o, [Rect? local]) => MatrixUtils.transformRect(
  o.getTransformTo(null),
  local ?? (Offset.zero & o.size),
);

/// The words on the screen with where they are, and the other things that take room (icons, pictures) as plain boxes.
(List<_Para>, List<Rect>) _ink(WidgetTester tester) {
  final window = Rect.fromLTWH(
    0,
    0,
    tester.view.physicalSize.width / tester.view.devicePixelRatio,
    tester.view.physicalSize.height / tester.view.devicePixelRatio,
  );
  final words = <_Para>[];
  for (final element in find.byType(RichText).evaluate()) {
    final o = element.renderObject;
    if (o is! RenderParagraph || !o.hasSize || !o.attached || _hidden(o)) {
      continue;
    }
    final route = ModalRoute.of(element);
    if (route != null && route.offstage) continue;
    final text = o.text.toPlainText();
    if (text.trim().isEmpty) continue;
    final boxes = o.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    if (boxes.isEmpty) continue;
    var rect = boxes.first.toRect();
    for (final b in boxes.skip(1)) {
      rect = rect.expandToInclude(b.toRect());
    }
    var box = _globalBox(o, rect);
    final whole = box.height;
    // What a list has scrolled out of its edge is not on the screen, whatever its box says
    final viewport = RenderAbstractViewport.maybeOf(o);
    if (viewport is RenderBox && (viewport as RenderBox).hasSize) {
      box = box.intersect(_globalBox(viewport as RenderBox));
      if (box.width <= 0 || box.height <= 0) {
        continue;
      }
    }
    if (box.overlaps(window) && box.width > 1 && box.height > 1) {
      words.add(
        _Para(
          box,
          text,
          o.didExceedMaxLines,
          route,
          inBar: element.findAncestorWidgetOfExactType<PlayerBarBody>() != null,
          partly: box.height < whole - 1,
          boxed:
              route is PopupRoute ||
              element.findAncestorWidgetOfExactType<Scrollable>()?.axis ==
                  Axis.horizontal,
        ),
      );
    }
  }
  final things = <Rect>[
    for (final type in [Icon, Image, LikeButton])
      for (final element in find.byType(type).evaluate())
        if (element.renderObject case final RenderBox box
            when box.hasSize && box.attached && !_hidden(box))
          _globalBox(box),
  ];
  return (words, things);
}

/// The rules about words: no two words on top of each other, no word cut while there is room beside it.
List<String> auditText(WidgetTester tester, Set<String> barLabels) {
  final found = <String>[];
  final (paragraphs, things) = _ink(tester);
  final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  String short(String s) {
    final one = s.replaceAll('\n', ' ');
    return one.length > 28 ? '${one.substring(0, 28)}…' : one;
  }

  // What shows through the glass bar under a page is chosen by the project (plan 5.3), so the labels of the tabs are
  // not "under" anything
  bool onBar(_Para p) =>
      barLabels.contains(p.text) && p.box.top > height * 0.75;

  for (var i = 0; i < paragraphs.length; i++) {
    for (var j = i + 1; j < paragraphs.length; j++) {
      final a = paragraphs[i];
      final b = paragraphs[j];
      if (a.route != b.route || onBar(a) || onBar(b)) continue;
      final section = a.box.intersect(b.box);
      if (section.width <= 0 || section.height <= 0) continue;
      final least = math.min(
        a.box.width * a.box.height,
        b.box.width * b.box.height,
      );
      if (section.width * section.height > 0.2 * least) {
        found.add(
          'overlap: "${short(a.text)}" over "${short(b.text)}" at ${section.left.round()},${section.top.round()} ${section.width.round()}x${section.height.round()}',
        );
      }
    }
  }

  for (final p in paragraphs) {
    if (!p.cut || p.inBar || p.boxed || p.partly) {
      continue;
    }
    // What is on the same line to the right of the cut word, or else the edge of the window
    var next = width - 16;
    final others = [
      for (final q in paragraphs)
        if (!identical(q, p) && !onBar(q)) q.box,
      ...things,
    ];
    for (final q in others) {
      if (q.left < p.box.right - 1) continue;
      final shared =
          math.min(q.bottom, p.box.bottom) - math.max(q.top, p.box.top);
      // Any shared height: a button is centred on a row of two lines and touches only one of them
      if (shared > 0) next = math.min(next, q.left);
    }
    final room = next - p.box.right;
    // A glyph sits in a button of 48 dp, so 12 dp of the gap beside it are the button's own padding, and the same again
    // is the row's: up to 36 is the make of the row, not room to spare
    if (room > 36) {
      found.add(
        'cut-with-room: "${short(p.text)}" is cut, ${room.round()} dp free beside it',
      );
    }
  }
  return found;
}

/// Flutter's own checks: contrast of text, the size of what can be tapped, and that what can be tapped is named.
Future<List<String>> auditGuidelines(WidgetTester tester) async {
  final found = <String>[];
  final checks = <String, AccessibilityGuideline>{
    'contrast': textContrastGuideline,
    'tap-size-android': androidTapTargetGuideline,
    'tap-size-ios': iOSTapTargetGuideline,
    'unlabeled': labeledTapTargetGuideline,
  };
  for (final MapEntry(:key, :value) in checks.entries) {
    final result = await value.evaluate(tester);
    if (!result.passed) {
      // One entry per node: its own line, then the sentence that says what is wrong with it
      var entry = '';
      void flush() {
        if (entry.isNotEmpty) found.add('$key: $entry');
        entry = '';
      }

      for (final raw in result.reason?.split('\n') ?? const <String>[]) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('See also')) continue;
        if (line.contains('SemanticsNode#')) {
          flush();
          entry = _plain(line);
        } else if (line.startsWith('Expected') || line.contains('expected')) {
          entry = entry.isEmpty ? line : '$entry $line';
        }
      }
      flush();
    }
  }
  return found;
}

final _rect = RegExp(
  r'Rect\.fromLTRB\(([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)',
);
final _label = RegExp(r'label: "([^"]*)"');

/// A line of Flutter's, with the node number taken out: `"label" 232x42 at 24,164: what is wrong`.
String _plain(String line) {
  final r = _rect.firstMatch(line);
  final l = _label.firstMatch(line);
  if (r == null) return line;
  double n(int i) => double.parse(r.group(i)!);
  final at = line.lastIndexOf('): ');
  final what = at >= 0 ? line.substring(at + 3) : '';
  return '"${l?.group(1) ?? ''}" ${(n(3) - n(1)).round()}x${(n(4) - n(2)).round()} at ${n(1).round()},${n(2).round()} $what'
      .trimRight();
}
