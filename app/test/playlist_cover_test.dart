import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/artwork.dart';
import 'package:sapoche/ui/widgets/playlist_cover.dart';

void main() {
  Future<void> pumpCover(WidgetTester tester, List<String> thumbs) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Palette.light),
          home: Scaffold(body: PlaylistCover(thumbs: thumbs, size: 100)),
        ),
      );

  testWidgets('four pictures make a grid of four', (tester) async {
    await pumpCover(tester, ['a', 'b', 'c', 'd']);
    expect(find.byType(Artwork), findsNWidgets(4));
    final sizes = tester
        .widgetList<Artwork>(find.byType(Artwork))
        .map((a) => a.size);
    expect(sizes, everyElement(50));
  });

  testWidgets('fewer than four pictures show the first one whole', (
    tester,
  ) async {
    await pumpCover(tester, ['a', 'b', 'c']);
    expect(find.byType(Artwork), findsOneWidget);
    expect(tester.widget<Artwork>(find.byType(Artwork)).url, 'a');
    expect(tester.widget<Artwork>(find.byType(Artwork)).size, 100);
  });

  testWidgets('no pictures show the placeholder', (tester) async {
    await pumpCover(tester, []);
    expect(tester.widget<Artwork>(find.byType(Artwork)).url, isNull);
  });

  test('a playlist reads the pictures of its cover', () {
    final playlist = SavedPlaylist.fromMap({
      'id': 1,
      'name': 'Mix',
      'count': 5,
      'thumbs': ['a', 'b'],
    });
    expect(playlist.thumbs, ['a', 'b']);
    expect(SavedPlaylist.fromMap({'id': 2, 'name': 'Empty'}).thumbs, isEmpty);
  });
}
