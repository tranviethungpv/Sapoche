import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/on_screen.dart';

void main() {
  testWidgets('knows when it is scrolled out of the list that holds it, though the list still builds it', (
    tester,
  ) async {
    final seen = <bool>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: ListView(
            controller: scroll,
            children: [
              OnScreen(
                builder: (context, visible) {
                  seen.add(visible);
                  return const SizedBox(key: ValueKey('mine'), height: 100);
                },
              ),
              const SizedBox(height: 900),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(seen.last, isTrue);

    scroll.jumpTo(150);
    await tester.pump();
    await tester.pump();
    expect(seen.last, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(seen.last, isTrue);
  });
}
