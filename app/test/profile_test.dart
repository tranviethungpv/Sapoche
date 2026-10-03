import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/widgets/avatars.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

// A 1x1 transparent PNG: enough for an image that decodes
final _png = Uint8List.fromList([
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0, //
  0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120,
  156, 99, 248, 255, 255, 63, 0, 5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0,
  73, 69, 78, 68, 174, 66, 96, 130,
]);

/// Starts on the home page, ready, and opens the settings.
Future<FakeBackend> settings(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  PhotoPicker? photoPicker,
}) async {
  final (backend, _) = await pumpApp(
    tester,
    listen: false,
    prefs: prefs,
    photoPicker: photoPicker,
  );
  backend.emit(const StateEvent(RoomSnapshot()));
  await tester.pumpAndSettle();
  await openSettingsList(tester);
  return backend;
}

void main() {
  testWidgets('the name can be changed outside a room', (tester) async {
    final backend = await settings(tester);
    expect(find.text('Anna'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Bình');
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('rename Bình'));
    expect(find.text('Bình'), findsOneWidget);
    expect(find.text('Anna'), findsNothing);
  });

  testWidgets('a name left as it was is not sent again', (tester) async {
    final backend = await settings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.startsWith('rename')), isEmpty);
  });

  testWidgets('a photo can be chosen, is kept, and can be removed', (
    tester,
  ) async {
    final backend = await settings(tester, photoPicker: () async => _png);
    expect(
      tester.widget<Avatar>(find.byType(Avatar).first).image,
      isNull,
      reason: 'it starts with the initial',
    );
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-remove')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profile-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-remove')), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('avatar'), isNotNull);
    expect(
      backend.calls.where(
        (c) => c.startsWith('setAvatar ') && c != 'setAvatar null',
      ),
      hasLength(1),
      reason: 'the room is given the picture',
    );
    await tester.tap(find.byKey(const ValueKey('profile-remove')));
    await tester.pumpAndSettle();
    expect(prefs.getString('avatar'), isNull);
    expect(
      backend.calls.last,
      'setAvatar null',
      reason: 'and told when it goes',
    );
  });

  testWidgets('a picture already chosen is there when the app opens', (
    tester,
  ) async {
    await settings(
      tester,
      prefs: {
        'avatar': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      },
    );
    expect(tester.widget<Avatar>(find.byType(Avatar).first).image, isNotNull);
  });

  testWidgets('backing out of the picker changes nothing', (tester) async {
    await settings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-remove')), findsNothing);
  });

  testWidgets('others in the room are shown with their pictures', (
    tester,
  ) async {
    final backend = await settings(tester);
    backend.emit(StateEvent(sampleRoom()));
    await tester.pumpAndSettle();
    final room = AppScope.roomOf(tester.element(find.byType(Scaffold).first));
    final other = room.snapshot.members.firstWhere(
      (m) => m.id != room.snapshot.you,
    );
    expect(room.avatarOf(other.id), isNull);
    backend.emit(AvatarEvent(other.id, _png));
    await tester.pump();
    expect(room.avatarOf(other.id), _png);
    backend.emit(AvatarEvent(other.id, null));
    await tester.pump();
    expect(room.avatarOf(other.id), isNull);
    backend.emit(AvatarEvent(other.id, _png));
    await tester.pump();
    // Someone who has left takes the picture with them
    backend.emit(
      StateEvent(
        sampleRoom(
          members: const [Member(id: 'me', name: 'Anna', ready: true)],
        ),
      ),
    );
    await tester.pump();
    expect(room.avatarOf(other.id), isNull);
  });
}
