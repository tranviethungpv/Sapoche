import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/connect/connect_controller.dart';
import 'package:sapoche/data/connect/connect_wire.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/sync/sync_crypto.dart';
import 'package:sapoche/data/web/local_session.dart';

import '../fake_backend.dart';
import 'fake_cluster.dart';

class MemoryConnectStore implements ConnectStore {
  MemoryConnectStore(this.values);
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// A [ConnectController] over [cluster] for the device whose backend is [backend].
ConnectController connectFor(
  FakeBackend backend,
  FakeCluster cluster,
  SyncKey key,
  String clientId, {
  DeviceKind kind = DeviceKind.phone,
  String name = 'Phone',
  Duration grace = const Duration(milliseconds: 150),
}) => ConnectController(
  inner: backend,
  syncChanges: ChangeNotifier(),
  syncKey: () => key,
  server: () async => Uri.parse('http://server'),
  serverKey: () async => 'k',
  store: MemoryConnectStore({'client': clientId}),
  kind: () => kind,
  defaultName: () => name,
  opener: cluster.opener,
  heartbeat: const Duration(milliseconds: 200),
  queueBeat: const Duration(milliseconds: 400),
  queueSettle: const Duration(milliseconds: 20),
  handoverGrace: grace,
);

/// What the native side would answer to `queueExport` for [songs] songs of the sample room.
QueueHandover sampleHandover({int songs = 3, int index = 0, int positionMs = 5000, int dropped = 0}) => QueueHandover(
  jsonEncode(SavedQueue(queue: sampleRoom(local: true, members: const []).queue.take(songs).toList(), index: index, positionMs: positionMs).toJson()),
  dropped,
);

/// Waits in real time, for a widget test (its own clock is a fake one) to let messages travel: the network and the sealing
/// run on the real clock, what the controllers of the app were made under is the fake one, and a pump lets that go on.
Future<void> waitReal(WidgetTester tester, bool Function() ok, {String? why}) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: ${why ?? 'a condition'}');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

/// Another device of the person, [name], that plays the sample queue: what the device of the test then steers.
class RemoteDevice {
  RemoteDevice(FakeCluster cluster, SyncKey key, {String name = 'Living room', DeviceKind kind = DeviceKind.tv, String clientId = 'rrrrrrrr-remote'})
    : backend = FakeBackend() {
    connect = connectFor(backend, cluster, key, clientId, kind: kind, name: name);
  }

  final FakeBackend backend;
  late final ConnectController connect;

  Future<void> startPlaying(WidgetTester tester) async {
    await tester.runAsync(connect.start);
    backend.handover = sampleHandover();
    backend.emit(StateEvent(sampleRoom(local: true, members: const [])));
    backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 5000, durationMs: 200000)));
    await tester.pump(); // what the backend said reaches the controller
    await waitReal(tester, () => connect.playingHere, why: 'the remote device plays');
  }
}
