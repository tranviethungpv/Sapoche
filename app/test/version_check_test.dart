import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/version_check.dart';

VersionCheck _check(String? body, {String loaded = '1.32.0+68'}) =>
    VersionCheck(loaded: loaded, fetch: () async => body);

void main() {
  test('the same version is not news', () async {
    final body = '{"app_name":"sapoche","version":"1.32.0","build_number":"68"}';
    expect(await _check(body).newer(), isNull);
  });

  test('another version is news, and says which', () async {
    final body = '{"version":"1.33.0","build_number":"69"}';
    expect(await _check(body).newer(), '1.33.0+69');
  });

  test('the same name with another build number is news', () async {
    final body = '{"version":"1.32.0","build_number":"70"}';
    expect(await _check(body).newer(), '1.32.0+70');
  });

  test('what cannot be read is nothing new', () async {
    expect(await _check(null).newer(), isNull);
    expect(await _check('not json').newer(), isNull);
    expect(await _check('{"build_number":"3"}').newer(), isNull);
    final failing = VersionCheck(loaded: '1.0.0+1', fetch: () async => throw Exception('offline'));
    expect(await failing.newer(), isNull);
  });
}
