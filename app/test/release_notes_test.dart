import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/release_history.dart';
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

  testWidgets(
    'settings has a page of the notes of every version, with this one marked',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Sapoche',
        packageName: 'app.sapoche',
        version: '1.24.0',
        buildNumber: '56',
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
      expect(find.text('1.24.0'), findsOneWidget);
      expect(find.text(S.releaseNotesInstalled), findsOneWidget);
      // The newest is open: its notes are there to read
      expect(find.text(heading), findsOneWidget);
      // An old one is shut until it is touched: its words are not there, its version is
      expect(find.text(all.last.version), findsOneWidget);
      expect(find.text(oldHeading), findsNothing);
      await tester.ensureVisible(find.text(all.last.version));
      // Clear of the bars that float over the foot of the page
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text(all.last.version));
      await tester.pumpAndSettle();
      expect(find.text(oldHeading), findsOneWidget);
    },
  );
}
