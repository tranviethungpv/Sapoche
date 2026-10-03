import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/setup_link.dart';

void main() {
  test('a setup link gives the server and the key', () {
    final link = SetupLink.parse(
      'sapoche://setup?server=https%3A%2F%2Fsapoche.example.dev&key=k3y%2Bx',
    )!;
    expect(link.server, 'https://sapoche.example.dev');
    expect(link.key, 'k3y+x');
    expect(link.host, 'sapoche.example.dev');
  });

  test(
    'a link pasted among other words is found, and a closing slash goes',
    () {
      final link = SetupLink.parse(
        'Here: sapoche://setup?server=https://a.example/&key=abc thanks',
      )!;
      expect(link.server, 'https://a.example');
      expect(link.key, 'abc');
    },
  );

  test('the key may be left out', () {
    expect(
      SetupLink.parse('sapoche://setup?server=https://a.example')!.key,
      '',
    );
  });

  test('only an https server is taken, and only from a setup link', () {
    expect(SetupLink.parse('sapoche://setup?server=http://a.example'), isNull);
    expect(SetupLink.parse('sapoche://setup?server=a.example'), isNull);
    expect(SetupLink.parse('sapoche://setup?key=abc'), isNull);
    expect(SetupLink.parse('sapoche://join/ABC234'), isNull);
    expect(
      SetupLink.parse('https://a.example/?server=https://b.example'),
      isNull,
    );
    expect(SetupLink.parse(''), isNull);
  });
}
