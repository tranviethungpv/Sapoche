import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/ios_update.dart';

IosUpdateCheck _check(String? body, {String installed = '1.32.0'}) =>
    IosUpdateCheck(installed: installed, fetch: () async => body);

String _release(String tag, {String body = 'Notes', bool draft = false, bool pre = false}) =>
    '{"tag_name":"$tag","html_url":"https://github.com/x/y/releases/tag/$tag","body":"$body","draft":$draft,"prerelease":$pre}';

void main() {
  test('a newer release is an offer with its notes and page', () async {
    final offer = await _check(_release('v1.33.0', body: ' Widgets ')).newer();
    expect(offer!.version, '1.33.0');
    expect(offer.notes, 'Widgets');
    expect(offer.url, 'https://github.com/x/y/releases/tag/v1.33.0');
  });

  test('the same version or an older one is not news', () async {
    expect(await _check(_release('v1.32.0')).newer(), isNull);
    expect(await _check(_release('v1.31.9')).newer(), isNull);
  });

  test('versions are compared by number, not by letters', () async {
    expect(await _check(_release('1.10.0'), installed: '1.9.0').newer(), isNotNull);
    expect(await _check(_release('1.9.0'), installed: '1.10.0').newer(), isNull);
  });

  test('a draft or a pre-release is not offered', () async {
    expect(await _check(_release('v2.0.0', draft: true)).newer(), isNull);
    expect(await _check(_release('v2.0.0', pre: true)).newer(), isNull);
  });

  test('what cannot be read is nothing new', () async {
    expect(await _check(null).newer(), isNull);
    expect(await _check('not json').newer(), isNull);
    expect(await _check('{"tag_name":"v9.0.0"}').newer(), isNull);
    expect(await _check('{"tag_name":"nightly","html_url":"u"}').newer(), isNull);
    final failing = IosUpdateCheck(installed: '1.0.0', fetch: () async => throw Exception('offline'));
    expect(await failing.newer(), isNull);
  });
}
