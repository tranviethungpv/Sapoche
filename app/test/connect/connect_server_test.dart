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

class _Memory implements ConnectStore {
  _Memory(this.values);
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Two devices against a real Worker (`wrangler dev --local`): `SYNC_SERVER=http://127.0.0.1:8790 SYNC_KEY=<the ROOM_KEY it was
/// started with> flutter test test/connect/connect_server_test.dart`. Skipped without them, as it needs a server. The messages
/// are the ones of `connect_test.dart`, over a real WebSocket and the real Durable Object.
void main() {
  const server = String.fromEnvironment('SYNC_SERVER');
  const roomKey = String.fromEnvironment('SYNC_KEY');

  test('two devices move the playing between them through the real server', skip: server.isEmpty ? 'SYNC_SERVER is not set' : null, () async {
    final key = SyncKey.generate();
    final made = <ConnectController>[];
    (FakeBackend, ConnectController) device(String clientId, String name) {
      final backend = FakeBackend();
      final c = ConnectController(
        inner: backend,
        syncChanges: ChangeNotifier(),
        syncKey: () => key,
        server: () async => Uri.parse(server),
        serverKey: () async => roomKey,
        store: _Memory({'client': clientId}),
        kind: () => DeviceKind.phone,
        defaultName: () => name,
        queueSettle: const Duration(milliseconds: 20),
      );
      made.add(c);
      return (backend, c);
    }

    Future<void> until(bool Function() ok, String why) async {
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out: $why');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    try {
      final (aBackend, a) = device('aaaaaaaa-1111-2222', 'Phone');
      final (bBackend, b) = device('bbbbbbbb-3333-4444', 'TV');
      await a.start();
      await b.start();
      await until(() => a.devices.length == 2 && b.devices.length == 2, 'both see both');
      expect(b.devices.firstWhere((d) => !d.you).info?.name, 'Phone');

      final room = sampleRoom(local: true, members: const []);
      aBackend.handover = QueueHandover(jsonEncode(SavedQueue(queue: room.queue, index: 1, positionMs: 12000).toJson()), 0);
      aBackend.emit(StateEvent(sampleRoom(local: true, members: const [], index: 1)));
      aBackend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 12000, durationMs: 200000)));
      await until(() => a.playingHere && b.controlling && b.remoteQueue != null, 'a plays and b steers');
      expect(b.remote?.current?.title, 'Song 1');

      expect(b.send(const RemoteCommand('seek', {'ms': 30000})), isTrue);
      await until(() => aBackend.calls.contains('seek 30000'), 'a is steered');

      b.playHere();
      await until(() => b.playingHere && bBackend.calls.any((c) => c.startsWith('queueImport')), 'b takes over');
      final imported = bBackend.calls.singleWhere((c) => c.startsWith('queueImport'));
      expect(jsonDecode(imported.substring(imported.indexOf('{')))['index'], 1);
      expect(aBackend.calls, containsAllInOrder(['seek 30000', 'pause', 'queueExport']));
      await until(() => a.activeId == b.youId, 'a knows b plays');
    } finally {
      for (final c in made) {
        c.dispose();
      }
    }
  });
}
