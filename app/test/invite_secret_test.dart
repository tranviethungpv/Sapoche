import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/invite_secret.dart';

void main() {
  final secret = 'A' * 43;

  test('reads the room and the secret out of the links the app and the server write', () {
    final web = InviteSecret.parse('https://sapoche.example.dev/join/abc234#k=$secret')!;
    expect((web.room, web.secret), ('ABC234', secret));
    final own = InviteSecret.parse('sapoche://join/ABC234?k=$secret')!;
    expect((own.room, own.secret), ('ABC234', secret));
    final both = InviteSecret.parse('https://sapoche.example.dev/join/ABC234#x=1&k=$secret')!;
    expect(both.secret, secret);
  });

  test('finds a link in the middle of a message', () {
    final found = InviteSecret.parse('Join me! https://sapoche.example.dev/join/ABC234#k=$secret see you');
    expect(found!.secret, secret);
  });

  test('a link with no secret, or a wrong one, has the room alone', () {
    expect(InviteSecret.parse('https://sapoche.example.dev/join/ABC234')!.secret, isNull);
    expect(InviteSecret.parse('https://sapoche.example.dev/join/ABC234#k=short')!.secret, isNull);
    expect(InviteSecret.parse('https://sapoche.example.dev/join/ABC234#k=${'A' * 44}')!.secret, isNull);
  });

  test('a bare code is a room, and anything else is not', () {
    expect(InviteSecret.parse(' abc234 ')!.room, 'ABC234');
    expect(InviteSecret.parse('hello'), isNull);
    expect(InviteSecret.parse('https://sapoche.example.dev/elsewhere/ABC234'), isNull);
    expect(InviteSecret.parse('https://sapoche.example.dev/join/ABC'), isNull);
    expect(InviteSecret.parse(''), isNull);
  });
}
