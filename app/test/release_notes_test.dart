import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/release_history.dart';
import 'package:sapoche/data/update_info.dart';
import 'package:sapoche/strings.dart';

import 'pump_app.dart';

/// The first thing the page says of a release: its heading, or the words of the first bullet.
String firstLine(String notes) {
  final line = notes.split('\n').first.trim();
  return line.startsWith('- ') ? line.substring(2).trim() : line;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('versions are ordered as numbers, not as words', () {
    final versions = ['1.9.0', '1.10.0', '1.2.0', '1.10.1', '1.9.10']
      ..sort(ReleaseHistory.compare);
    expect(versions, ['1.2.0', '1.9.0', '1.9.10', '1.10.0', '1.10.1']);
  });

  test('every version that was released is in the app, newest first, with its notes', () async {
    final entries = await ReleaseHistory.load(rootBundle);
    final files = Directory('release-notes')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => RegExp(r'^\d+(\.\d+)*\.txt$').hasMatch(n))
        .map((n) => n.substring(0, n.length - 4))
        .toList();
    expect(entries.length, files.length);
    expect(entries.length, greaterThan(20));
    // The newest is the version the app says it is
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version: (\S+)\+',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(entries.first.version, version);
    for (var i = 1; i < entries.length; i++) {
      expect(
        ReleaseHistory.compare(entries[i - 1].version, entries[i].version),
        greaterThan(0),
      );
    }
    expect(entries.every((e) => e.notes.trim().isNotEmpty), isTrue);
    expect(
      entries.first.notes,
      File('release-notes/$version.txt').readAsStringSync(),
    );
  });

  test('the notes come in Vietnamese when asked, and in English where there are none', () async {
    final vi = await ReleaseHistory.load(rootBundle, language: 'vi');
    final newest = vi.first;
    expect(
      newest.notes,
      File('release-notes/${newest.version}.vi.txt').readAsStringSync(),
    );
    final onlyEnglish = Directory('release-notes')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => RegExp(r'^\d+(\.\d+)*\.txt$').hasMatch(n))
        .map((n) => n.substring(0, n.length - 4))
        .where((v) => !File('release-notes/$v.vi.txt').existsSync());
    for (final version in onlyEnglish) {
      expect(
        vi.firstWhere((e) => e.version == version).notes,
        File('release-notes/$version.txt').readAsStringSync(),
      );
    }
  });

  test('the versions can be listed without reading their notes, and read a few at a time', () async {
    final versions = await ReleaseHistory.versions(rootBundle);
    final all = await ReleaseHistory.load(rootBundle);
    expect(versions, [for (final e in all) e.version]);
    final some = await ReleaseHistory.read(
      rootBundle,
      versions.skip(2).take(3),
    );
    expect(some.map((e) => e.version), versions.skip(2).take(3));
    expect(some.first.notes, all[2].notes);
  });

  testWidgets(
    'settings has a page of the notes, five versions at first and ten more each time asked, with this one marked',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Sapoche',
        packageName: 'app.sapoche',
        // The version that is in this tree, which is the newest of the notes listed
        version: RegExp(r'^version: (\S+)\+', multiLine: true)
            .firstMatch(File('pubspec.yaml').readAsStringSync())![1]!,
        buildNumber: '58',
        buildSignature: '',
      );
      final all = (await tester.runAsync(
        () => ReleaseHistory.load(rootBundle),
      ))!;
      final newest = all.first;
      final heading = firstLine(newest.notes);
      final oldHeading = firstLine(all.last.notes);
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.emit(const StateEvent(RoomSnapshot()));
      await tester.pumpAndSettle();
      await openSettingsList(tester);
      await tester.tap(find.byKey(const ValueKey('settings-release-notes')));
      // The notes are read from the assets, which takes real time; the wheel in the meantime never stops turning
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('release-history')), findsOneWidget);
      expect(find.text(newest.version), findsOneWidget);
      expect(find.text(S.releaseNotesInstalled), findsOneWidget);
      // The newest is open: its notes are there to read
      expect(find.text(heading), findsOneWidget);
      // Only the newest five are listed, and the older ones can be asked for
      expect(find.text(all[4].version), findsOneWidget);
      expect(find.text(all[5].version), findsNothing);
      final older = find.byKey(const ValueKey('release-history-older'));
      expect(older, findsOneWidget);

      Future<void> askForOlder() async {
        await tester.ensureVisible(older);
        // Clear of the bars that float over the foot of the page
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pumpAndSettle();
        await tester.tap(older);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
      }

      await askForOlder();
      expect(find.text(all[14].version, skipOffstage: false), findsOneWidget);
      expect(find.text(all[15].version, skipOffstage: false), findsNothing);
      while (older.evaluate().isNotEmpty) {
        await askForOlder();
      }
      // An old one is shut until it is touched: its words are not there, its version is
      expect(find.text(all.last.version), findsOneWidget);
      expect(find.text(oldHeading), findsNothing);
      await tester.ensureVisible(find.text(all.last.version));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text(all.last.version));
      await tester.pumpAndSettle();
      expect(find.text(oldHeading), findsOneWidget);
    },
  );

  test(
    'the notes of the versions to come are read from what the update says',
    () {
      final info = UpdateInfo.fromJson({
        'phase': 'available',
        'installed': '1.27.0',
        'version': '1.28.0',
        'upcoming': [
          {'version': '1.28.0', 'notes': 'Newer\n- a'},
          {'version': '1.27.5', 'notes': 'In between'},
          {'notes': 'no version'},
        ],
      });
      expect(info.upcoming.map((e) => e.version), ['1.28.0', '1.27.5']);
      expect(info.upcoming.first.notes, 'Newer\n- a');
      expect(UpdateInfo.fromJson({'phase': 'upToDate'}).upcoming, isEmpty);
    },
  );

  testWidgets(
    'the page lists the versions the phone has not got, open and marked new, above the ones it has',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Sapoche',
        packageName: 'app.sapoche',
        version: '1.26.0',
        buildNumber: '58',
        buildSignature: '',
      );
      final all = (await tester.runAsync(
        () => ReleaseHistory.load(rootBundle),
      ))!;
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.emit(const StateEvent(RoomSnapshot()));
      backend.emit(
        UpdateEvent(
          UpdateInfo(
            phase: UpdatePhase.available,
            installed: all.first.version,
            version: '99.1.0',
            upcoming: [
              const ReleaseEntry(
                '99.1.0',
                'Heading of the next\n- Something new',
              ),
              const ReleaseEntry('99.0.5', 'Heading in between\n- Another'),
              // One the app has in it is shown from there, once
              ReleaseEntry(all.first.version, 'From the server'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openSettingsList(tester);
      await tester.tap(find.byKey(const ValueKey('settings-release-notes')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('release-history-hint')),
        findsOneWidget,
      );
      expect(find.text('99.1.0'), findsOneWidget);
      expect(find.text('99.0.5'), findsOneWidget);
      expect(find.text(S.releaseNotesNew), findsNWidgets(2));
      // They are open: their words are there
      expect(find.text('Heading of the next'), findsOneWidget);
      expect(find.text('Heading in between'), findsOneWidget);
      expect(find.text('From the server'), findsNothing);
      expect(find.text(all.first.version), findsOneWidget);
      // Newest first, and above the versions in the app
      expect(
        tester.getTopLeft(find.text('99.1.0')).dy,
        lessThan(tester.getTopLeft(find.text('99.0.5')).dy),
      );
      expect(
        tester.getTopLeft(find.text('99.0.5')).dy,
        lessThan(tester.getTopLeft(find.text(all.first.version)).dy),
      );
    },
  );

  testWidgets('with nothing to come, the page has no hint and no new mark', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Sapoche',
      packageName: 'app.sapoche',
      version: '1.26.0',
      buildNumber: '58',
      buildSignature: '',
    );
    final (backend, _) = await pumpApp(tester, listen: false);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await openSettingsList(tester);
    await tester.tap(find.byKey(const ValueKey('settings-release-notes')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('release-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('release-history-hint')), findsNothing);
    expect(find.text(S.releaseNotesNew), findsNothing);
  });
}
