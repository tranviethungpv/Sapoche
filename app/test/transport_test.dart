import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/transport.dart';

void main() {
  for (final filled in [true, false]) {
    testWidgets(
      'the wait on the ${filled ? 'full' : 'mini'} play button is a whole circle with an arc running round it',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Palette.dark),
            home: Center(
              child: PlayPauseButton(
                playing: false,
                starting: true,
                onPressed: () {},
                filled: filled,
              ),
            ),
          ),
        );
        final ring = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        );
        expect(ring.backgroundColor, isNotNull);
        expect(ring.backgroundColor!.a, lessThan(ring.color!.a));
      },
    );
  }
}
