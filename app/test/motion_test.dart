import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/ui/widgets/appear.dart';
import 'package:sapoche/ui/widgets/motion.dart';

/// The interface's motion: none longer than 300 ms, and none at all while the system asks for less or the phone is
/// warm, in battery saver or set to "Light effects" (`docs/plans/2026-11-11-ui-polish.md`, G11).
void main() {
  tearDown(() => Calm.chosen = null);

  Widget host({required bool reduce, required Widget child}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: MaterialApp(home: Scaffold(body: child)),
  );

  double opacityOf(WidgetTester tester, Finder inside) => tester
      .widget<FadeTransition>(
        find.ancestor(of: inside, matching: find.byType(FadeTransition)).first,
      )
      .opacity
      .value;

  test('no motion takes longer than 300 ms', () {
    for (final ms in [Motion.short, Motion.medium, Motion.long]) {
      expect(ms, lessThanOrEqualTo(300));
    }
  });

  group('the durations', () {
    testWidgets('are given as asked, and none when reduced by the system', (
      tester,
    ) async {
      late BuildContext context;
      Future<void> pump(bool reduce) => tester.pumpWidget(
        host(
          reduce: reduce,
          child: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await pump(false);
      expect(Motion.of(context, 240), const Duration(milliseconds: 240));
      expect(Motion.sheet(context).duration, const Duration(milliseconds: 280));
      await pump(true);
      expect(Motion.of(context, 240), Duration.zero);
      expect(Motion.sheet(context), AnimationStyle.noAnimation);
    });

    testWidgets('are none while the phone is asked to do less', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        host(
          reduce: false,
          child: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      Calm.chosen = true;
      expect(Motion.reduced(context), isTrue);
      expect(Motion.of(context, 240), Duration.zero);
      Calm.chosen = false;
      expect(Motion.reduced(context), isFalse);
    });
  });

  group('somebody who comes in', () {
    const face = SizedBox(key: ValueKey('face'), width: 40, height: 40);

    testWidgets('pops in over under 300 ms', (tester) async {
      await tester.pumpWidget(
        host(reduce: false, child: const Pop(animate: true, child: face)),
      );
      expect(opacityOf(tester, find.byKey(const ValueKey('face'))), 0);
      await tester.pump(const Duration(milliseconds: 150));
      final half = opacityOf(tester, find.byKey(const ValueKey('face')));
      expect(half, greaterThan(0));
      expect(half, lessThan(1));
      await tester.pump(const Duration(milliseconds: 160));
      expect(opacityOf(tester, find.byKey(const ValueKey('face'))), 1);
    });

    testWidgets(
      'is there at once when reduced, or when they were already here',
      (tester) async {
        await tester.pumpWidget(
          host(reduce: true, child: const Pop(animate: true, child: face)),
        );
        expect(opacityOf(tester, find.byKey(const ValueKey('face'))), 1);
        await tester.pumpWidget(
          host(reduce: false, child: const Pop(animate: false, child: face)),
        );
        expect(opacityOf(tester, find.byKey(const ValueKey('face'))), 1);
      },
    );

    testWidgets('and with Light effects on', (tester) async {
      Calm.chosen = true;
      await tester.pumpWidget(
        host(reduce: false, child: const Pop(animate: true, child: face)),
      );
      expect(opacityOf(tester, find.byKey(const ValueKey('face'))), 1);
    });
  });

  group('a song that is added to the queue', () {
    const row = SizedBox(key: ValueKey('row'), width: 40, height: 40);

    testWidgets('slides in over 300 ms, and not at all when reduced', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(reduce: false, child: const Appear(animate: true, child: row)),
      );
      expect(opacityOf(tester, find.byKey(const ValueKey('row'))), 0);
      await tester.pump(const Duration(milliseconds: 310));
      expect(opacityOf(tester, find.byKey(const ValueKey('row'))), 1);
      await tester.pumpWidget(
        host(
          reduce: true,
          child: const Appear(
            animate: true,
            child: SizedBox(key: ValueKey('row2'), width: 40, height: 40),
          ),
        ),
      );
      expect(opacityOf(tester, find.byKey(const ValueKey('row2'))), 1);
    });
  });
}
