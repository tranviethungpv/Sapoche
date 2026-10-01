import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/setup_link.dart';

void main() {
  test('a setup link gives the server and the key', () {
    final link = SetupLink.parse(
      'unison://setup?server=https%3A%2F%2Funison.example.dev&key=k3y%2Bx',
    )!;
    expect(link.server, 'https://unison.example.dev');
    expect(link.key, 'k3y+x');
    expect(link.host, 'unison.example.dev');
  });

  test(
    'a link pasted among other words is found, and a closing slash goes',
    () {
      final link = SetupLink.parse(
        'Here: unison://setup?server=https://a.example/&key=abc thanks',
      )!;
      expect(link.server, 'https://a.example');
      expect(link.key, 'abc');
    },
  );

  test('the key may be left out', () {
    expect(SetupLink.parse('unison://setup?server=https://a.example')!.key, '');
  });

  test('only an https server is taken, and only from a setup link', () {
    expect(SetupLink.parse('unison://setup?server=http://a.example'), isNull);
    expect(SetupLink.parse('unison://setup?server=a.example'), isNull);
    expect(SetupLink.parse('unison://setup?key=abc'), isNull);
    expect(SetupLink.parse('unison://join/ABC234'), isNull);
    expect(
      SetupLink.parse('https://a.example/?server=https://b.example'),
      isNull,
    );
    expect(SetupLink.parse(''), isNull);
  });
}
