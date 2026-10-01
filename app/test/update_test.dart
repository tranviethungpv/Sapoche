import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/update_info.dart';

import 'pump_app.dart';

UpdateEvent news(
  UpdatePhase phase, {
  String? version = '1.3.0',
  int size = 28000000,
  int done = 0,
  String? error,
  String? notes,
}) => UpdateEvent(
  UpdateInfo(
    phase: phase,
    installed: '1.2.0',
    version: version,
    notes: notes,
    size: size,
    done: done,
    error: error,
  ),
);

void main() {
  test('the native side describes an update in json', () {
    final info = UpdateInfo.fromJson({
      'phase': 'downloading',
      'installed': '1.2.0',
      'version': '1.3.0',
      'notes': '  ',
      'size': 100,
      'done': 25,
      'error': null,
    });
    expect(info.phase, UpdatePhase.downloading);
    expect(info.notes, isNull, reason: 'blank notes are no notes');
    expect(info.progress, 0.25);
    expect(info.hasUpdate, isTrue);
    expect(UpdateInfo.fromJson({'phase': 'nonsense'}).phase, UpdatePhase.idle);
  });

  test('every phase the native side can send is understood', () {
    // Kotlin's UiJson.update writes these names; one of them once came out as needs_permission and read as idle
    const sent = {
      'idle': UpdatePhase.idle,
      'checking': UpdatePhase.checking,
      'upToDate': UpdatePhase.upToDate,
      'available': UpdatePhase.available,
      'downloading': UpdatePhase.downloading,
      'ready': UpdatePhase.ready,
      'needsPermission': UpdatePhase.needsPermission,
      'installing': UpdatePhase.installing,
      'failed': UpdatePhase.failed,
    };
    sent.forEach((name, phase) {
      expect(UpdateInfo.fromJson({'phase': name}).phase, phase, reason: name);
    });
    expect(UpdatePhase.parse('needs_permission'), UpdatePhase.needsPermission);
    expect(UpdatePhase.parse('UP_TO_DATE'), UpdatePhase.upToDate);
    expect(UpdatePhase.parse(null), UpdatePhase.idle);
    expect(sent.length, UpdatePhase.values.length);
  });

  testWidgets('a dot on the gear tells that a newer version waits', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Badge>(find.byKey(const ValueKey('update-dot')))
          .isLabelVisible,
      isFalse,
    );
    backend.emit(news(UpdatePhase.available));
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(
      tester
          .widget<Badge>(find.byKey(const ValueKey('update-dot')))
          .isLabelVisible,
      isTrue,
    );
    backend.emit(news(UpdatePhase.upToDate, version: null));
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(
      tester
          .widget<Badge>(find.byKey(const ValueKey('update-dot')))
          .isLabelVisible,
      isFalse,
    );
  });

  testWidgets('the settings row shows the version, or the new one', (
    tester,
  ) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(news(UpdatePhase.upToDate, version: null));
    await openSettingsList(tester);
    expect(find.text('1.2.0'), findsOneWidget);
    backend.emit(news(UpdatePhase.available));
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(find.text('1.3.0'), findsOneWidget);
  });

  group('the updates page', () {
    testWidgets('checks when asked', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.upToDate, version: null));
      await openTopic(tester, 'updates');
      expect(find.text('Unison is up to date'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pump();
      expect(backend.calls, contains('updateCheck'));
    });

    testWidgets('offers a version, with what is new and its size', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.available, notes: 'Faster start'));
      await openTopic(tester, 'updates');
      expect(find.text('Version 1.3.0 is available'), findsOneWidget);
      expect(find.text('Faster start'), findsOneWidget);
      expect(find.text('26.7 MB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pump();
      expect(backend.calls, contains('updateDownload false'));
    });

    testWidgets(
      'shows the notes with their headings and bullets, line by line',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(
          news(
            UpdatePhase.available,
            notes: 'Smoother\n- 120 Hz everywhere\n- Calmer player\nRooms\n- Names offered',
          ),
        );
        await openTopic(tester, 'updates');
        final notes = find.byKey(const ValueKey('release-notes'));
        expect(
          find.descendant(of: notes, matching: find.text('Smoother')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: notes, matching: find.text('Rooms')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: notes, matching: find.text('120 Hz everywhere')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: notes, matching: find.text('Names offered')),
          findsOneWidget,
        );
        // One bullet for each of the three lines that start with "- "
        expect(
          find.descendant(of: notes, matching: find.text('•')),
          findsNWidgets(3),
        );
      },
    );

    testWidgets('asks before using mobile data', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.updateOnWifi = false;
      backend.emit(news(UpdatePhase.available));
      await openTopic(tester, 'updates');
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      expect(find.text('Use mobile data?'), findsOneWidget);
      await tester.tap(find.text('Download').last);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('updateDownload true'));
    });

    testWidgets('does not download after a no', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.updateOnWifi = false;
      backend.emit(news(UpdatePhase.available));
      await openTopic(tester, 'updates');
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('updateDownload true')));
    });

    testWidgets('shows how far the download has come', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.downloading, size: 1000, done: 400));
      await openTopic(tester, 'updates');
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('update-progress')),
      );
      expect(bar.value, 0.4);
      expect(find.byKey(const ValueKey('update-action')), findsNothing);
    });

    testWidgets('warns that the app closes before installing', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.ready));
      await openTopic(tester, 'updates');
      expect(find.text('Version 1.3.0 is ready to install'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      expect(find.text('Install the update?'), findsOneWidget);
      expect(backend.calls, isNot(contains('updateInstall')));
      await tester.tap(find.text('Install').last);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('updateInstall'));
    });

    testWidgets(
      'explains and opens Android’s page when installing is not yet allowed',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.mayInstall = false;
        backend.emit(news(UpdatePhase.ready));
        await openTopic(tester, 'updates');
        await tester.tap(find.byKey(const ValueKey('update-action')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Install').last);
        await tester.pumpAndSettle();
        expect(find.text('Allow installing updates'), findsOneWidget);
        expect(backend.calls, isNot(contains('updateAllowInstalls')));
        await tester.tap(find.byKey(const ValueKey('update-open-settings')));
        await tester.pumpAndSettle();
        expect(backend.calls, contains('updateAllowInstalls'));
      },
    );

    testWidgets('lets the person decline to open that page', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.mayInstall = false;
      backend.emit(news(UpdatePhase.ready));
      await openTopic(tester, 'updates');
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('updateAllowInstalls')));
    });

    testWidgets('does not ask when installing goes ahead', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.ready));
      await openTopic(tester, 'updates');
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install').last);
      await tester.pumpAndSettle();
      expect(find.text('Allow installing updates'), findsNothing);
    });

    testWidgets('leaves the install alone after a no', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.ready));
      await openTopic(tester, 'updates');
      await tester.tap(find.byKey(const ValueKey('update-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.calls, isNot(contains('updateInstall')));
    });

    testWidgets('sends the person to the page that allows installs', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.needsPermission));
      await openTopic(tester, 'updates');
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(backend.calls, contains('updateAllowInstalls'));
    });

    testWidgets('says in words what went wrong, and offers another go', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(news(UpdatePhase.failed, error: 'signature'));
      await openTopic(tester, 'updates');
      expect(find.textContaining('different key'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(backend.calls, contains('updateDownload false'));
    });

    testWidgets('a failed check offers a new check, not a download', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(
        news(UpdatePhase.failed, version: null, error: 'unreachable'),
      );
      await openTopic(tester, 'updates');
      expect(find.textContaining('reach the server'), findsOneWidget);
      await tester.tap(find.text('Check for updates'));
      await tester.pump();
      expect(backend.calls, contains('updateCheck'));
    });
  });
}
