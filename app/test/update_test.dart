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
