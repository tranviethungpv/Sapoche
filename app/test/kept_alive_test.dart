import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/kept_alive.dart';

/// A row that is empty until its answer comes, like the home page's rows that wait for the network.
class _Late extends StatefulWidget {
  const _Late();

  @override
  State<_Late> createState() => _LateState();
}

class _LateState extends State<_Late> {
  late final Future<int> _answer = Future.value(1);

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: _answer,
    builder: (context, answer) => answer.data == null
        ? const SizedBox.shrink()
        : const SizedBox(height: 400, child: Text('late')),
  );
}

Map<String, double> _tops(WidgetTester tester) => {
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    text.data!: tester.getTopLeft(find.byWidget(text)).dy,
};

/// Walks down a page with a late row in it, then flings back up it. Gives the biggest step any row made that its scrolling
/// does not account for: how far the page was sent in one frame by something that grew.
Future<double> _biggestJerk(WidgetTester tester, {required bool kept}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 12; i++)
              SizedBox(height: 200, child: Text('row $i')),
            kept ? const KeptAlive(child: _Late()) : const _Late(),
            for (var i = 12; i < 30; i++)
              SizedBox(height: 200, child: Text('row $i')),
          ],
        ),
      ),
    ),
  );
  final position = tester
      .state<ScrollableState>(find.byType(Scrollable))
      .position;
  for (var i = 0; i < 40; i++) {
    await tester.fling(find.byType(ListView), const Offset(0, -300), 2000);
    await tester.pumpAndSettle();
  }
  var biggest = 0.0;
  for (var round = 0; round < 25 && position.pixels > 0; round++) {
    await tester.fling(find.byType(ListView), const Offset(0, 300), 3000);
    var before = _tops(tester);
    var at = position.pixels;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = _tops(tester);
      final moved = position.pixels - at;
      // A row that is still there has moved by what the page scrolled and no more (the first frame after a touch is
      // left out: the drag starts then)
      if (frame > 0) {
        for (final row in now.entries) {
          final was = before[row.key];
          if (was == null) continue;
          final step = ((row.value - was) + moved).abs();
          if (step > biggest) biggest = step;
        }
      }
      before = now;
      at = position.pixels;
    }
  }
  return biggest;
}

void main() {
  testWidgets('a late row built again on the way back sends the page down', (
    tester,
  ) async {
    expect(await _biggestJerk(tester, kept: false), greaterThan(100));
  });

  testWidgets('a kept row comes back with its height and nothing jerks', (
    tester,
  ) async {
    expect(await _biggestJerk(tester, kept: true), lessThan(10));
  });
}
