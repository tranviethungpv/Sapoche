import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';

import 'chat_test.dart' show history, message;
import 'fake_backend.dart';
import 'png_fixture.dart';
import 'pump_app.dart';

void main() {
  /// In a room of Anna (this device), Binh and Chi, with the list of who is there open.
  Future<FakeBackend> openMembers(
    WidgetTester tester, {
    List<Member>? members,
    String? ownerId,
    String phase = 'playing',
  }) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(
      StateEvent(
        sampleRoom(
          phase: phase,
          ownerId: ownerId,
          members:
              members ??
              const [
                Member(id: 'me', name: 'Anna', ready: true),
                Member(id: 'b', name: 'Binh', ready: true),
                Member(id: 'c', name: 'Chi', ready: true, solo: true),
              ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('listening'));
    await tester.pumpAndSettle();
    return backend;
  }

  /// The sheet of a person, as against the mini player and the queue behind it.
  final profile = find.byKey(const ValueKey('member-profile'));

  Future<void> openProfile(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('member-$id')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'touching someone in the room opens who they are and what the room plays',
    (tester) async {
      await openMembers(tester);
      await openProfile(tester, 'b');
      expect(find.text(S.profileListeningTo), findsOneWidget);
      expect(
        find.descendant(of: profile, matching: find.text('Binh')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: profile, matching: find.text(S.statusListening)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: profile, matching: find.text('Song 0')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: profile, matching: find.text('Artist 0')),
        findsOneWidget,
      );
      // Songs 1 of 0..2 are Binh's
      expect(find.text(S.profileQueued(1)), findsOneWidget);
    },
  );

  testWidgets(
    'someone on their own is not said to hear the room, because what they play is not known',
    (tester) async {
      await openMembers(tester);
      await openProfile(tester, 'c');
      expect(find.text(S.profileAloneNote), findsOneWidget);
      expect(
        find.descendant(of: profile, matching: find.text('Song 0')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'someone whose connection is lost says so, and an idle room says nothing plays',
    (tester) async {
      await openMembers(
        tester,
        members: const [
          Member(id: 'me', name: 'Anna', ready: true),
          Member(id: 'b', name: 'Binh', ready: true, away: true),
        ],
      );
      await openProfile(tester, 'b');
      expect(find.text(S.profileAwayNote), findsOneWidget);
    },
  );

  testWidgets(
    'you can edit your own profile from yours, and cannot remove yourself',
    (tester) async {
      await openMembers(tester, ownerId: 'me');
      await openProfile(tester, 'me');
      expect(find.text(S.you), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-view-remove')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('profile-view-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-name')), findsOneWidget);
    },
  );

  testWidgets(
    'only the owner can remove someone from their profile, and is asked first',
    (tester) async {
      final backend = await openMembers(
        tester,
        ownerId: 'me',
        members: const [
          Member(id: 'me', name: 'Anna', ready: true, owner: true),
          Member(id: 'b', name: 'Binh', ready: true),
        ],
      );
      await openProfile(tester, 'b');
      expect(find.text(S.owner), findsNothing, reason: 'Binh is a guest');
      await tester.tap(find.byKey(const ValueKey('profile-view-remove')));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('kick')), isEmpty);
      await tester.tap(find.text(S.remove));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('kick b'));
    },
  );

  testWidgets('a guest sees no way to remove anyone, and the owner is marked', (
    tester,
  ) async {
    await openMembers(
      tester,
      ownerId: 'b',
      members: const [
        Member(id: 'me', name: 'Anna', ready: true),
        Member(id: 'b', name: 'Binh', ready: true, owner: true),
      ],
    );
    await openProfile(tester, 'b');
    expect(find.text(S.owner), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-view-remove')), findsNothing);
  });

  group('the picture', () {
    testWidgets('can be looked at closer, pinched, and put away', (
      tester,
    ) async {
      final backend = await openMembers(tester);
      backend.emit(AvatarEvent('b', solidPng(200, 80, 120, side: 64)));
      await tester.pumpAndSettle();
      await openProfile(tester, 'b');

      await tester.tap(find.byKey(const ValueKey('profile-view-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-zoom')), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('avatar-zoom')),
      );
      expect(viewer.maxScale, greaterThan(1));
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);

      // A double touch zooms in, another zooms out
      final at = tester.getCenter(find.byKey(const ValueKey('avatar-zoom')));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(
        viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1.5),
      );
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);

      await tester.tap(find.byKey(const ValueKey('avatar-zoom-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-zoom')), findsNothing);
      // The profile is still there underneath
      expect(find.byKey(const ValueKey('profile-view-photo')), findsOneWidget);
    });

    testWidgets('goes away with a touch outside it', (tester) async {
      final backend = await openMembers(tester);
      backend.emit(AvatarEvent('b', solidPng(200, 80, 120, side: 64)));
      await tester.pumpAndSettle();
      await openProfile(tester, 'b');
      await tester.tap(find.byKey(const ValueKey('profile-view-photo')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(270, 60));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-zoom')), findsNothing);
    });

    testWidgets('of someone who has none is a letter, with nothing to zoom', (
      tester,
    ) async {
      await openMembers(tester);
      await openProfile(tester, 'b');
      await tester.tap(find.byKey(const ValueKey('profile-view-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('avatar-zoom')), findsNothing);
    });
  });

  testWidgets(
    'a profile still open when its person leaves says they have left',
    (tester) async {
      final backend = await openMembers(tester);
      await openProfile(tester, 'b');
      backend.emit(
        StateEvent(
          sampleRoom(
            members: const [Member(id: 'me', name: 'Anna', ready: true)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(S.profileGone), findsOneWidget);
    },
  );

  testWidgets('the picture beside a message in the chat opens who wrote it', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(StateEvent(sampleRoom()));
    backend.emit(history([message(1, 'b', 'hello')]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(S.chat));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-avatar-1')));
    await tester.pumpAndSettle();
    expect(profile, findsOneWidget);
    expect(find.descendant(of: profile, matching: find.text('Binh')), findsOneWidget);
  });
}
