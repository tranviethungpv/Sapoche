import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/preview_backend.dart';
import 'package:unison/data/room_controller.dart';

void main() {
  test('the stand-in backend lets the app leave its splash screen', () async {
    final room = RoomController(PreviewBackend());
    expect(room.ready, isFalse);
    await room.start();
    await Future<void>.delayed(Duration.zero);
    expect(room.ready, isTrue);
    expect(room.profile.name, 'iPhone');
  });
}
