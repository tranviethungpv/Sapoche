import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/format.dart';
import 'package:sapoche/strings.dart';

void main() {
  tearDown(() => S.current = 'en');

  group('formatCount', () {
    test('keeps a short number and shortens the rest', () {
      expect(formatCount(430), '430');
      expect(formatCount(1200), '1.2K');
      expect(formatCount(155000000), '155M');
      expect(formatCount(1835322339), '1.8B');
      expect(formatCount(999600), '1M');
    });

    test('says it in Vietnamese with a decimal comma', () {
      S.current = 'vi';
      expect(formatCount(1835322339), '1,8 Tỷ');
      expect(formatCount(155000000), '155 Tr');
      expect(formatCount(2500), '2,5 N');
    });
  });

  group('splitViews', () {
    test('takes the views out of a song or a video and drops the likes', () {
      expect(splitViews('155M plays').views, '155M plays');
      expect(splitViews('1.8B views · 19M likes').views, '1.8B views');
      expect(splitViews('1.8B views • 19M likes').text, '');
      expect(splitViews('430 views').views, '430 views');
      expect(splitViews('1,234 views').views, '1.2K views');
    });

    test('leaves what comes before the views as the text', () {
      final s = splitViews('YouTube Music · 1.2M views');
      expect(s.text, 'YouTube Music');
      expect(s.views, '1.2M views');
    });

    test('says it in the language of the app', () {
      S.current = 'vi';
      expect(splitViews('1.8B views · 19M likes').views, '1,8 Tỷ lượt xem');
      expect(splitViews('155M plays').views, '155 Tr lượt phát');
      expect(splitViews('430 views').views, '430 lượt xem');
    });

    test('leaves a line with no views alone, and keeps views it cannot read as they are', () {
      expect(splitViews('Anna · 2024').views, isNull);
      expect(splitViews('Anna · 2024').text, 'Anna · 2024');
      expect(splitViews('1.2M subscribers').views, isNull);
      expect(splitViews('1.8 billion views').views, '1.8 billion views');
      expect(splitViews(null).views, isNull);
    });
  });
}
