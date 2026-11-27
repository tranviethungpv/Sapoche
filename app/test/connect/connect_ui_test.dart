import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/connect/connect_controller.dart';
import 'package:sapoche/data/connect/connect_wire.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/sync/sync_crypto.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/connect_ui.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/player/parts.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/volume_bar.dart';

import '../fake_backend.dart';
import '../landscape_test.dart' show resize;
import '../pump_app.dart';
import 'fake_cluster.dart';
import 'harness.dart';

/// The button of where the sound goes, the sheet it opens and what the bars say, in every look of the player: the places of
/// the matrix of docs/plans/2026-11-27-listen-on-another-device.md (G10).
void main() {
  late FakeCluster cluster;
  late SyncKey key;
  ConnectController? mine;
  final remotes = <RemoteDevice>[];

  /// A widget test that lets go of the devices before it ends: the timers of their connections are not left pending.
  void uiTest(String name, Future<void> Function(WidgetTester tester) body, {bool skip = false}) => testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      mine?.dispose();
      for (final r in remotes) {
        r.connect.dispose();
      }
      remotes.clear();
    }
  }, skip: skip);

  setUp(() {
    cluster = FakeCluster();
    key = SyncKey.generate();
    mine = null;
  });

  /// The app of the test, with the devices of the person: [remote] plays when it is given.
  Future<(FakeBackend, RemoteDevice?)> openApp(WidgetTester tester, PlayerStyle style, {bool remotePlays = false}) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    final (backend, _) = await pumpApp(
      tester,
      prefs: {'player_style': style.name},
      connect: (backend) {
        final c = mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone');
        return c;
      },
    );
    if (remotePlays) {
      await remote.startPlaying(tester);
      await waitReal(tester, () => mine!.controlling && mine!.remoteQueue != null, why: 'the app steers the remote');
    } else {
      await tester.runAsync(remote.connect.start);
      backend.emit(StateEvent(sampleRoom(local: true, members: const [])));
      backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000)));
      await tester.pump();
      await waitReal(tester, () => mine!.devices.length == 2, why: 'the app sees the remote');
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tapMiniPlayer(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    return (backend, remote);
  }

  Finder tip(String label) => find.byTooltip(label);

  for (final style in PlayerStyle.values) {
    group('the player of $style', () {
      uiTest('the button says where the sound is and opens the devices', (tester) async {
        await openApp(tester, style);
        expect(find.byType(NowPlayingPage), findsOneWidget);
        // Nobody else plays: the button is the one of the outputs of this device
        expect(tip(S.playOn), findsOneWidget);
        await tester.tap(tip(S.playOn));
        await tester.pumpAndSettle();
        expect(find.byType(ConnectSheet), findsOneWidget);
        expect(find.byKey(const ValueKey('connect-here')), findsOneWidget);
        expect(find.text('My phone'), findsOneWidget);
        // The other device of the person is on the list, and a tap moves the playing to it
        expect(find.text('Living room'), findsOneWidget);
        await tester.tap(find.text('Living room'));
        await tester.pumpAndSettle();
        await waitReal(tester, () => cluster.sent.any((s) => s.$2['t'] == 'transfer'), why: 'the transfer is asked');
        expect(cluster.sent.where((s) => s.$2['t'] == 'transfer'), hasLength(1));
        expect(tester.takeException(), isNull);
      });

      uiTest('while another device plays the player shows it, and what is pressed goes there', (tester) async {
        final (backend, remote) = await openApp(tester, style, remotePlays: true);
        await tester.pump(const Duration(milliseconds: 100));
        // Lit up, and saying which device
        expect(tip(S.playOnDevice('Living room')), findsOneWidget);
        expect(tip(S.playOn), findsNothing);
        expect(find.text(S.playingOn('Living room')), findsWidgets);
        // The volume is the other device's, also in a browser
        expect(find.byType(VolumeBar), findsOneWidget);
        // The song and the queue are the playing device's
        expect(find.text('Song 0'), findsWidgets);
        // The play button steers it: the player of this device is left alone
        await tester.tap(find.byIcon(Icons.pause_rounded).first);
        await waitReal(tester, () => remote!.backend.calls.contains('pause'), why: 'the remote device is paused');
        expect(backend.calls, isNot(contains('pause')));
        // The sheet marks the one that plays
        await tester.tap(tip(S.playOnDevice('Living room')));
        await tester.pumpAndSettle();
        expect(find.text(S.devicePlaying), findsNWidgets(1));
        // The sheet has the volume of the other device too, to reach from the bar and from every look of the player
        final inSheet = find.descendant(of: find.byType(ConnectSheet), matching: find.byType(VolumeBar));
        expect(inSheet, findsOneWidget);
        await tester.drag(inSheet, const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 150)); // the volume goes out now and then
        await waitReal(tester, () => remote!.backend.calls.any((c) => c.startsWith('setVolume')), why: 'the volume reaches the other device');
        expect(backend.calls.where((c) => c.startsWith('setVolume')), isEmpty, reason: 'this device\'s own volume is left alone');
        await tester.tap(find.byKey(const ValueKey('connect-here')));
        await tester.pumpAndSettle();
        expect(find.text(S.movingHere), findsOneWidget, reason: 'the person is told the hand-over has begun');
        await waitReal(tester, () => cluster.sent.any((s) => s.$2['t'] == 'transfer'), why: 'the transfer is asked');
        expect(cluster.sent.where((s) => s.$1 == 'mmmmmmmm-mine' && s.$2['t'] == 'transfer'), hasLength(1));
        expect(tester.takeException(), isNull);
      });

      uiTest('on its side the menu has the line of the devices', (tester) async {
        await openApp(tester, style, remotePlays: true);
        await resize(tester, 844, 390);
        expect(tester.takeException(), isNull);
        await tester.tap(find.descendant(of: find.byType(NowPlayingPage), matching: find.byType(PlayerMoreButton)));
        await tester.pumpAndSettle();
        expect(find.text(S.playOnDevice('Living room')), findsOneWidget);
        // The menu is longer than the screen on its side
        await tester.ensureVisible(find.text(S.playOnDevice('Living room')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(S.playOnDevice('Living room')));
        await tester.pumpAndSettle();
        expect(find.byType(ConnectSheet), findsOneWidget);
      });
    });
  }

  uiTest('the mini player says where the sound is in place of the artist', (tester) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    await pumpApp(
      tester,
      connect: (backend) {
        final c = mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone');
        return c;
      },
    );
    await remote.startPlaying(tester);
    await waitReal(tester, () => mine!.controlling && mine!.remoteQueue != null);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.descendant(of: find.byType(MiniPlayerCapsule), matching: find.text(S.playingOn('Living room'))), findsOneWidget);
    expect(find.descendant(of: find.byType(MiniPlayerCapsule), matching: find.text('Artist 0')), findsNothing);
    // A device of the person that goes away leaves the song, as the last one that played, in its place
    remote.connect.dispose();
    cluster.drop('rrrrrrrr-remote');
    await waitReal(tester, () => !mine!.controlling);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.descendant(of: find.byType(MiniPlayerCapsule), matching: find.text(S.playingOn('Living room'))), findsNothing);
  });

  uiTest('with nobody playing, this device row asks to play here from the last queue and carries no "Playing" mark', (tester) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    await pumpApp(tester, connect: (backend) => mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone'));
    await tester.runAsync(remote.connect.start);
    await waitReal(tester, () => mine!.devices.length == 2, why: 'the app sees the remote');
    showConnectSheet(tester.element(find.byType(Scaffold).first), AppScope.roomOf(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
    expect(find.text(S.devicePlaying), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connect-here')));
    await tester.pumpAndSettle();
    await waitReal(tester, () => cluster.sent.any((s) => s.$1 == 'mmmmmmmm-mine' && s.$2['t'] == 'transfer'), why: 'the transfer is asked');
  });

  uiTest('a device is renamed from the sheet, and the others see the new name', (tester) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    await pumpApp(tester, connect: (backend) => mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone'));
    await tester.runAsync(remote.connect.start);
    await waitReal(tester, () => mine!.devices.length == 2, why: 'the app sees the remote');
    showConnectSheet(tester.element(find.byType(Scaffold).first), AppScope.roomOf(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connect-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Kitchen');
    await tester.tap(find.text(S.save));
    await tester.pump();
    await waitReal(tester, () => remote.connect.devices.any((d) => d.info?.name == 'Kitchen'), why: 'the remote sees the new name');
    await tester.pumpAndSettle();
    expect(find.text('Kitchen'), findsOneWidget);
  });

  uiTest('a device that is not here is listed dimmed with when it was seen, and can be forgotten', (tester) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    await pumpApp(tester, connect: (backend) => mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone'));
    await tester.runAsync(remote.connect.start);
    await waitReal(tester, () => mine!.devices.length == 2, why: 'the app sees the remote');
    remote.connect.dispose();
    await waitReal(tester, () => mine!.recent.length == 1, why: 'the remote is seen as gone');
    final id = mine!.recent.single.id;
    showConnectSheet(tester.element(find.byType(Scaffold).first), AppScope.roomOf(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
    expect(find.text(S.devicesRecent), findsOneWidget);
    expect(find.text('Living room'), findsOneWidget);
    expect(find.text('${S.deviceOffline} · ${S.ago(Duration.zero)}'), findsOneWidget);
    // It is not one to play on: a touch on the row does nothing
    await tester.tap(find.byKey(ValueKey('connect-recent-$id')));
    await tester.pumpAndSettle();
    expect(cluster.sent.where((s) => s.$2['t'] == 'transfer'), isEmpty);
    expect(find.byType(ConnectSheet), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('connect-forget-$id')));
    await tester.pumpAndSettle();
    expect(find.text(S.devicesRecent), findsNothing);
    await waitReal(tester, () => cluster.sent.any((s) => s.$1 == 'mmmmmmmm-mine' && s.$2['t'] == 'forget' && s.$2['id'] == id), why: 'the server is asked to forget');
  });

  uiTest('while another device plays, the volume buttons of the phone are for it, and a small bar says where it is', (tester) async {
    final remote = RemoteDevice(cluster, key);
    remotes.add(remote);
    await pumpApp(tester, connect: (backend) => mine = connectFor(backend, cluster, key, 'mmmmmmmm-mine', name: 'My phone'));
    // Nobody is steered yet: a button is the system's
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp), isFalse);
    await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);

    await remote.startPlaying(tester);
    remote.backend.emit(const VolumeEvent(0.5));
    await tester.pump();
    await waitReal(tester, () => mine!.controlling && mine!.remote?.volume == 0.5, why: 'the app steers the remote');
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp), isTrue, reason: 'the press is taken: the phone does not change its own');
    await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.pump(const Duration(milliseconds: 200)); // the volume goes out in a moment (the clock of the test is a fake one)
    await waitReal(tester, () => remote.backend.calls.contains('setVolume 0.5625'), why: 'the playing device is asked');
    expect(find.descendant(of: find.byType(SnackBar), matching: find.text('Living room')), findsOneWidget);
    expect(find.descendant(of: find.byType(SnackBar), matching: find.byType(LinearProgressIndicator)), findsOneWidget);
    await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
    await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget, reason: 'one bar that moves, not a new one for each press');
    // It goes away by itself
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(mine!.devices.length, 2);
    debugDefaultTargetPlatformOverride = null;
  });

  uiTest('without a sync key the sheet says what to do', (tester) async {
    await pumpApp(
      tester,
      connect: (backend) => mine = ConnectController(
        inner: backend,
        syncChanges: ChangeNotifier(),
        syncKey: () => null,
        server: () async => Uri.parse('http://server'),
        serverKey: () async => '',
        store: MemoryConnectStore({}),
        kind: () => DeviceKind.phone,
        defaultName: () => 'Phone',
        opener: cluster.opener,
      ),
    );
    expect(mine!.enabled, isFalse);
    showConnectSheet(tester.element(find.byType(Scaffold).first), AppScope.roomOf(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
    expect(find.text(S.connectNeedSync), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-here')), findsOneWidget);
    expect(find.text(S.yourDevices), findsNothing);
  });
}
