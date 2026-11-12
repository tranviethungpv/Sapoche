import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/marquee_text.dart';
import 'package:sapoche/ui/widgets/meta_line.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// `docs/plans/2026-11-12-ui-fixed-yardstick.md` group B (K7): one rule for text that does not fit its place.
void main() {
  Future<void> pumpLine(WidgetTester tester, double width, {String? lead = 'Song', String? meta = '205M plays'}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: SizedBox(
                width: width,
                child: MetaLine(text: 'Sơn Tùng M-TP', lead: lead, meta: meta),
              ),
            ),
          ),
        ),
      );

  String shown(WidgetTester tester) => tester.widget<Text>(find.descendant(of: find.byType(MetaLine), matching: find.byType(Text))).data!;

  group('the line under a title', () {
    testWidgets('shows the kind, the name and the count when they fit', (tester) async {
      await pumpLine(tester, 2000);
      expect(shown(tester), 'Song · Sơn Tùng M-TP · 205M plays');
    });

    testWidgets('gives up the kind first, then the count, and only then cuts the name', (tester) async {
      // Narrower and narrower: what the line says, each time it says something else
      final seen = <String>[];
      for (var width = 700.0; width >= 40; width -= 6) {
        await pumpLine(tester, width);
        if (seen.isEmpty || seen.last != shown(tester)) seen.add(shown(tester));
      }
      expect(seen, ['Song · Sơn Tùng M-TP · 205M plays', 'Sơn Tùng M-TP · 205M plays', 'Sơn Tùng M-TP']);
      // Alone, the name is cut with its ellipsis, not left out
      final text = tester.widget<Text>(find.descendant(of: find.byType(MetaLine), matching: find.byType(Text)));
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('is the name alone with neither kind nor count', (tester) async {
      await pumpLine(tester, 2000, lead: null, meta: null);
      expect(shown(tester), 'Sơn Tùng M-TP');
    });
  });

  group('a long title', () {
    const title = 'A title that is a little too long for one line of this width';

    Future<void> pumpTitle(WidgetTester tester, int wrapLines, {double width = 300}) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: SizedBox(width: width, child: MarqueeText(title, wrapLines: wrapLines)),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('is on two lines, still, when two are allowed and enough', (tester) async {
      await pumpTitle(tester, 2, width: 600);
      final text = tester.widget<Text>(find.descendant(of: find.byType(MarqueeText), matching: find.byType(Text)));
      expect(text.maxLines, 2);
      expect(find.byType(Transform), findsNothing, reason: 'nothing runs');
    });

    testWidgets('runs when two lines are not enough', (tester) async {
      await pumpTitle(tester, 2, width: 90);
      expect(find.descendant(of: find.byType(MarqueeText), matching: find.byType(ClipRect)), findsOneWidget);
    });

    testWidgets('runs as it did when only one line is allowed', (tester) async {
      await pumpTitle(tester, 1);
      expect(find.descendant(of: find.byType(MarqueeText), matching: find.byType(ClipRect)), findsOneWidget);
    });
  });

  group('the three pills over the queue', () {
    Future<void> openQueue(WidgetTester tester, double width, {double text = 1.0, String language = 'en'}) async {
      final (backend, _) = await pumpApp(tester, prefs: {'language': language});
      tester.view
        ..devicePixelRatio = 2
        ..physicalSize = Size(width * 2, 1800);
      tester.platformDispatcher.textScaleFactorTestValue = text;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      S.current = language;
      backend.emit(StateEvent(sampleRoom(local: true, songs: 2)));
      backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tapMiniPlayer(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byTooltip(S.upNext));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Finder word(String label) => find.descendant(of: find.byType(Tooltip), matching: find.text(label));

    testWidgets('have their words when they fit', (tester) async {
      // Test text is the wide Ahem font, so the words fit when the text is a little smaller than usual
      await openQueue(tester, 540, text: 0.7);
      expect(word(S.shuffle), findsOneWidget);
      expect(word(S.repeat), findsOneWidget);
      expect(word(S.autoplay), findsOneWidget);
    });

    testWidgets('all give their words up together when the longest does not fit, none shrinks alone', (tester) async {
      await openQueue(tester, 360, text: 1.3, language: 'vi');
      expect(word(S.shuffle), findsNothing);
      expect(word(S.repeat), findsNothing);
      expect(word(S.autoplay), findsNothing);
      // The icons and the tooltips stay
      expect(find.byTooltip(S.autoplay), findsOneWidget);
    });
  });

  test('the headings are in sentence case', () {
    expect(S.upNext, 'Up next');
    expect(S.nowPlaying, 'Now playing');
  });
}
