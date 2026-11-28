import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/connect/connect_backend.dart';
import 'package:sapoche/data/connect/connect_client.dart';
import 'package:sapoche/data/connect/connect_controller.dart';
import 'package:sapoche/data/connect/connect_keys.dart';
import 'package:sapoche/data/connect/connect_wire.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/sync/sync_crypto.dart';
import 'package:sapoche/data/web/local_session.dart';
import 'package:sapoche/data/web/room_socket.dart';

import '../fake_backend.dart';
import 'fake_cluster.dart';

class _Memory implements ConnectStore {
  _Memory(this.values);
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// One device of the person: its backend, what it holds of Connect and what the screens of it would see.
class _Device {
  _Device(this.clientId, this.backend, this.connect, this.sync) : seen = [] {
    view = ConnectBackend(backend, connect);
    view.events.listen(seen.add);
  }

  final String clientId;
  final FakeBackend backend;
  final ConnectController connect;
  final ChangeNotifier sync;
  final List<BackendEvent> seen;
  late final ConnectBackend view;

  String get id => clientId.substring(0, 8);
  Iterable<StateEvent> get states => seen.whereType<StateEvent>();
}

Future<void> until(bool Function() ok, {String? why}) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: ${why ?? 'a condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final key = SyncKey.generate();
  late FakeCluster cluster;
  final made = <_Device>[];

  Future<_Device> device(String clientId, {SyncKey? withKey, DeviceKind kind = DeviceKind.phone, String name = 'Phone', Duration grace = const Duration(milliseconds: 150), bool buttonsAreLevels = false}) async {
    final backend = FakeBackend();
    final sync = ChangeNotifier();
    final connect = ConnectController(
      inner: backend,
      syncChanges: sync,
      syncKey: () => withKey ?? key,
      server: () async => Uri.parse('http://server'),
      serverKey: () async => 'k',
      store: _Memory({'client': clientId}),
      kind: () => kind,
      defaultName: () => name,
      opener: cluster.opener,
      heartbeat: const Duration(milliseconds: 200),
      queueBeat: const Duration(milliseconds: 400),
      queueSettle: const Duration(milliseconds: 20),
      handoverGrace: grace,
      buttonsAreLevels: buttonsAreLevels,
    );
    await connect.start();
    final d = _Device(clientId, backend, connect, sync);
    made.add(d);
    return d;
  }

  RoomSnapshot room({bool local = true, String phase = 'playing', int index = 0}) => sampleRoom(local: local, phase: phase, index: index, members: const []);

  /// What the native side would answer to `queueExport` for [songs] songs.
  QueueHandover handover({int songs = 3, int index = 0, int positionMs = 5000, int dropped = 0}) =>
      QueueHandover(jsonEncode(SavedQueue(queue: room().queue.take(songs).toList(), index: index, positionMs: positionMs).toJson()), dropped);

  /// [d] plays on its own (a button of its notification): it says so, and becomes the one that plays.
  Future<void> startPlaying(_Device d, {QueueHandover? queue}) async {
    d.backend.handover = queue ?? handover();
    d.backend.emit(StateEvent(room()));
    d.backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 5000, durationMs: 200000)));
    await until(() => d.connect.playingHere, why: '${d.id} plays');
  }

  setUp(() {
    cluster = FakeCluster();
    made.clear();
  });
  tearDown(() {
    for (final d in made) {
      d.connect.dispose();
    }
  });

  group('what a device is', () {
    DeviceKind detect(TargetPlatform platform, double dp, {bool web = false, bool tv = false}) =>
        DeviceKind.detect(web: web, platform: platform, tv: tv, shortSideDp: dp);

    test('a tablet is told from a phone by the short side of its screen, on both systems', () {
      expect(detect(TargetPlatform.android, 412), DeviceKind.phone);
      expect(detect(TargetPlatform.android, 800), DeviceKind.tablet);
      expect(detect(TargetPlatform.iOS, 390), DeviceKind.iphone);
      expect(detect(TargetPlatform.iOS, 744), DeviceKind.ipad);
    });

    test('a TV is a TV whatever its size, and a browser is a computer only on a computer', () {
      expect(detect(TargetPlatform.android, 1080, tv: true), DeviceKind.tv);
      expect(detect(TargetPlatform.windows, 900, web: true), DeviceKind.computer);
      expect(detect(TargetPlatform.macOS, 900, web: true), DeviceKind.computer);
      expect(detect(TargetPlatform.android, 412, web: true), DeviceKind.web);
    });

    test('a kind an older app does not know reads as a phone, and every kind survives the seal', () {
      expect(DeviceKind.parse('hologram'), DeviceKind.phone);
      for (final kind in DeviceKind.values) {
        expect(DeviceInfo.fromJson(DeviceInfo(name: 'x', kind: kind).toJson())?.kind, kind);
      }
    });
  });

  group('sealing', () {
    test('what is sealed opens with the same key only, and a long text is packed', () async {
      final a = await ConnectSecrets.of(key);
      final b = await ConnectSecrets.of(SyncKey.generate());
      final long = jsonEncode({'queue': List.generate(300, (i) => 'a song of the queue number $i')});
      for (final text in ['short', long]) {
        final sealed = await ConnectSeal.seal(text, a);
        expect(sealed, isNot(contains(text)));
        expect(await ConnectSeal.open(sealed, a), text);
        expect(await ConnectSeal.open(sealed, b), isNull, reason: 'another key');
      }
      expect((await ConnectSeal.seal(long, a)).length, lessThan(long.length), reason: 'gzip makes it shorter');
      expect(await ConnectSeal.open('not a seal', a), isNull);
      expect(a.clusterId, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.token, isNot(a.clusterId));
    });
  });

  group('the devices of a person', () {
    test('each sees the others, with the name and the kind they gave', () async {
      final a = await device('aaaaaaaa-phone', name: 'Anna phone');
      final b = await device('bbbbbbbb-tv', kind: DeviceKind.tv, name: 'Living room');
      await until(() => a.connect.devices.length == 2 && b.connect.devices.length == 2);
      expect(a.connect.devices.first.you, isTrue);
      final other = a.connect.devices.firstWhere((d) => !d.you);
      expect(other.info?.name, 'Living room');
      expect(other.info?.kind, DeviceKind.tv);
      expect(b.connect.devices.firstWhere((d) => !d.you).info?.name, 'Anna phone');
    });

    test('a device with another key is not let in', () async {
      await device('aaaaaaaa-phone');
      final stranger = await device('cccccccc-other', withKey: SyncKey.generate());
      await until(() => stranger.connect.link == ConnectLink.refused);
      expect(stranger.connect.devices, isEmpty);
    });

    test('there is nothing to connect to without a key', () async {
      final backend = FakeBackend();
      final connect = ConnectController(
        inner: backend,
        syncChanges: ChangeNotifier(),
        syncKey: () => null,
        server: () async => Uri.parse('http://server'),
        serverKey: () async => '',
        store: _Memory({}),
        kind: () => DeviceKind.phone,
        defaultName: () => 'Phone',
        opener: cluster.opener,
      );
      await connect.start();
      expect(connect.enabled, isFalse);
      expect(connect.link, ConnectLink.off);
      connect.dispose();
    });

    test('a device that goes stays in the list of the ones seen, until it is forgotten', () async {
      final a = await device('aaaaaaaa-phone', name: 'Phone');
      final b = await device('bbbbbbbb-tv', kind: DeviceKind.tv, name: 'Living room');
      await until(() => a.connect.devices.length == 2);
      expect(a.connect.recent, isEmpty, reason: 'a device that is here is not one that was seen');
      b.connect.dispose();
      await until(() => a.connect.recent.length == 1 && a.connect.devices.length == 1, why: 'the TV is seen as gone');
      final gone = a.connect.recent.single;
      expect(gone.info?.name, 'Living room');
      expect(gone.info?.kind, DeviceKind.tv);
      expect(a.connect.seenAgo(gone), lessThan(const Duration(seconds: 5)));

      // The ones that come later are told of it too
      final c = await device('cccccccc-pad', kind: DeviceKind.tablet, name: 'Pad');
      await until(() => c.connect.recent.length == 1, why: 'the pad is told of the TV');

      a.connect.forget(gone.id);
      expect(a.connect.recent, isEmpty, reason: 'at once');
      await until(() => c.connect.recent.isEmpty, why: 'the others are told too');
      expect(cluster.known.containsKey(gone.id), isFalse);
    });

    test('a device that comes back is no more one that was seen, and a device that is here cannot be forgotten', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv', name: 'Living room');
      await until(() => a.connect.devices.length == 2);
      b.connect.dispose();
      await until(() => a.connect.recent.isNotEmpty);
      await device('bbbbbbbb-tv', name: 'Living room');
      await until(() => a.connect.recent.isEmpty && a.connect.devices.length == 2, why: 'the TV is back');
      final other = a.connect.devices.firstWhere((d) => !d.you);
      a.connect.forget(other.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.connect.devices.length, 2);
    });

    test('a line that is down tells nothing of the devices that were seen', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await until(() => a.connect.devices.length == 2);
      b.connect.dispose();
      await until(() => a.connect.recent.isNotEmpty);
      cluster.drop('aaaaaaaa-phone');
      await until(() => a.connect.recent.isEmpty || a.connect.link != ConnectLink.online);
      await until(() => a.connect.link == ConnectLink.online && a.connect.recent.length == 1, why: 'it is told again when the line is back');
    });

    test('a name given is what the others see', () async {
      final a = await device('aaaaaaaa-phone', name: 'Phone');
      final b = await device('bbbbbbbb-tv');
      await until(() => b.connect.devices.length == 2);
      await a.connect.rename('Anna');
      await until(() => b.connect.devices.any((d) => d.info?.name == 'Anna'));
      expect(a.connect.name, 'Anna');
    });
  });

  group('a line that dies without a word', () {
    // A server that welcomes, then answers pings while [answers] says so, and never says that it is gone
    late List<_QuietSocket> opened;
    late bool answers;

    Future<ConnectClient> client(List<ConnectLink> links) async => ConnectClient(
      secrets: await ConnectSecrets.of(key),
      clientId: 'cccccccc-client',
      address: () async => Uri.parse('ws://server/connect/x'),
      info: () async => 'info',
      onMessage: (_) {},
      onLink: links.add,
      opener: (url, {required onOpen, required onMessage, required onClose}) {
        final socket = _QuietSocket(onMessage, () => answers);
        opened.add(socket);
        scheduleMicrotask(onOpen);
        return socket;
      },
      pingEvery: const Duration(milliseconds: 60),
      probeAfter: const Duration(milliseconds: 60),
      retryFirst: const Duration(milliseconds: 20),
    );

    setUp(() {
      opened = [];
      answers = true;
    });

    test('a line that stops answering is made again', () async {
      final links = <ConnectLink>[];
      final c = await client(links)
        ..start();
      await until(() => links.contains(ConnectLink.online));
      answers = false;
      await until(() => opened.length >= 2, why: 'a new line is opened');
      expect(links, containsAllInOrder([ConnectLink.connecting, ConnectLink.online, ConnectLink.offline]));
      expect(opened.first.closedWith, 4002);
      c.stop();
    });

    test('a line that answers is kept', () async {
      final links = <ConnectLink>[];
      final c = await client(links)
        ..start();
      await until(() => links.contains(ConnectLink.online));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(opened, hasLength(1));
      expect(links.last, ConnectLink.online);
      c.stop();
    });

    test('when the app comes back the line is asked, and made again at once if it does not answer', () async {
      final links = <ConnectLink>[];
      // Pings too far apart for the watch to find out: only the question on coming back can
      final c = ConnectClient(
        secrets: await ConnectSecrets.of(key),
        clientId: 'cccccccc-client',
        address: () async => Uri.parse('ws://server/connect/x'),
        info: () async => 'info',
        onMessage: (_) {},
        onLink: links.add,
        opener: (url, {required onOpen, required onMessage, required onClose}) {
          final socket = _QuietSocket(onMessage, () => answers);
          opened.add(socket);
          scheduleMicrotask(onOpen);
          return socket;
        },
        pingEvery: const Duration(minutes: 10),
        probeAfter: const Duration(milliseconds: 60),
        retryFirst: const Duration(milliseconds: 20),
      )..start();
      await until(() => links.contains(ConnectLink.online));
      c.nudge();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(opened, hasLength(1), reason: 'it answered: the line stays');
      answers = false;
      c.nudge();
      await until(() => opened.length >= 2, why: 'a new line after the silence');
      c.stop();
    });
  });

  group('one plays and the others steer', () {
    test('a device that starts to play is the one that plays; the others show what it plays', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await until(() => b.connect.devices.length == 2);
      await startPlaying(a);
      await until(() => b.connect.controlling && b.connect.remoteQueue != null);
      expect(b.connect.remote?.current?.title, 'Song 0');
      expect(b.connect.remote?.playing, isTrue);
      expect(b.connect.activeDevice?.info?.name, 'Phone');
      // What its screens see is the playing device's queue, as a device that is not in a room, and its position
      await until(() => b.states.any((s) => s.snapshot.queue.length == 3));
      final shown = b.states.last.snapshot;
      expect(shown.inRoom, isFalse);
      expect(shown.current?.title, 'Song 0');
      expect(shown.phase, 'playing');
      final position = b.seen.whereType<PositionEvent>().last.position;
      expect(position.playing, isTrue);
      expect(position.positionMs, greaterThanOrEqualTo(5000));
      expect(position.durationMs, 200000);
      // A device that plays does not show another
      expect(a.connect.controlling, isFalse);
    });

    test('what a controlling device presses is done on the playing one, and not on its own player', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      final songs = room().queue;
      await b.view.pause();
      await b.view.seek(9000);
      await b.view.jump('q2');
      await b.view.setShuffle(true);
      await b.view.setRepeat(Repeat.all);
      await b.view.addMany(songs.take(2).toList(), playNext: true, queued: true);
      await b.view.playList(songs, start: 1, label: 'Album');
      await b.view.move('q0', 2, queued: true);
      await b.view.remove('q1');
      await b.view.setVolume(0.4);
      await b.view.setSleep(SleepMode.time, minutes: 30);
      await until(() => a.backend.calls.contains('sleep time 30'));
      expect(a.backend.calls, containsAllInOrder(['pause', 'seek 9000', 'jump q2']));
      expect(a.backend.calls.any((c) => c.startsWith('playList video0,video1,video2 start=1 label=Album')), isTrue);
      expect(a.backend.calls.any((c) => c.startsWith('addMany')), isTrue);
      expect(a.backend.calls.any((c) => c.contains('move')), isTrue);
      expect(b.backend.calls, isNot(contains('pause')), reason: 'its own player is left alone');
      expect(b.backend.calls.where((c) => c.startsWith('seek') || c.startsWith('jump')), isEmpty);
    });

    test('the volume that a finger drags is sent now and then, the last of it, and what the player says back waits for the finger', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      for (var i = 1; i <= 30; i++) {
        await b.view.setVolume(i / 30);
      }
      await until(() => a.backend.calls.contains('setVolume 1.0'), why: 'the last volume arrives');
      final sent = a.backend.calls.where((c) => c.startsWith('setVolume')).length;
      expect(sent, lessThan(5), reason: 'not one message for every move of the finger');
      expect(b.backend.calls.where((c) => c.startsWith('setVolume')), isEmpty);
      // The volume of the player, said while the finger is still on the bar, is not put under it
      final before = b.seen.whereType<VolumeEvent>().length;
      a.backend.emit(const VolumeEvent(0.2));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(b.seen.whereType<VolumeEvent>().length, before);
    });

    test('a press of a volume button moves the volume of the device that plays by a step, and the bar follows at once', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      a.backend.emit(const VolumeEvent(0.5));
      await startPlaying(a);
      await until(() => b.connect.controlling && b.connect.remote?.volume == 0.5, why: 'the volume of the playing device is known');
      expect(a.connect.nudgeVolume(1), isNull, reason: 'the device that plays has its own buttons');
      expect(b.connect.nudgeVolume(1), 0.5625);
      expect(b.seen.whereType<VolumeEvent>().last.level, 0.5625, reason: 'before the other device has answered');
      expect(b.connect.nudgeVolume(1), 0.625, reason: 'a second press goes on from the first, not from the old level');
      expect(b.connect.nudgeVolume(-1), 0.5625);
      await until(() => a.backend.calls.contains('setVolume 0.5625'), why: 'the playing device is asked');
      expect(b.backend.calls.where((c) => c.startsWith('setVolume')), isEmpty, reason: 'the phone\'s own volume is not touched');
      for (var i = 0; i < 40; i++) {
        b.connect.nudgeVolume(1);
      }
      expect(b.seen.whereType<VolumeEvent>().last.level, 1.0, reason: 'the volume stops at the top');
    });

    test('an iPhone that steers another holds its own volume still, and takes a move of it for a press', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-phone', buttonsAreLevels: true);
      b.backend.emit(const VolumeEvent(0.9)); // at the top, where a button would show nothing
      a.backend.emit(const VolumeEvent(0.5));
      await startPlaying(a);
      await until(() => b.connect.controlling && b.connect.remote?.volume == 0.5);
      await until(() => b.backend.calls.contains('setVolume 0.5'), why: 'the phone is put in the middle');
      b.backend.calls.clear();
      b.backend.emit(const VolumeEvent(0.5625)); // a press of the up button
      await until(() => a.backend.calls.contains('setVolume 0.5625'), why: 'the press is the other device\'s');
      expect(b.backend.calls, ['setVolume 0.5'], reason: 'and the phone is put back');
      b.backend.emit(const VolumeEvent(0.5)); // what the putting back says
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.backend.calls.where((c) => c.startsWith('setVolume')).toSet(), {'setVolume 0.5625'}, reason: 'that is no press');
      // No more steering: the phone has its volume back
      a.connect.dispose();
      cluster.drop('aaaaaaaa-phone');
      await until(() => !b.connect.controlling);
      await until(() => b.backend.calls.contains('setVolume 0.9'), why: 'the volume of the phone is given back');
    });

    test('a pause, a play, a seek and the modes show at once on the device that presses them', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling && b.connect.remote != null);
      await until(() => b.seen.whereType<PositionEvent>().any((e) => e.position.playing));
      await b.view.pause();
      expect(b.seen.whereType<PositionEvent>().last.position.playing, isFalse, reason: 'before the other device has answered');
      await b.view.seek(42000);
      expect(b.seen.whereType<PositionEvent>().last.position.positionMs, 42000);
      await b.view.setShuffle(true);
      expect(b.states.last.snapshot.shuffle, isTrue);
      await b.view.play();
      expect(b.seen.whereType<PositionEvent>().last.position.playing, isTrue);
    });

    test('a device that is not controlling does what is pressed on its own player', () async {
      final a = await device('aaaaaaaa-phone');
      await a.view.pause();
      await a.view.seek(1000);
      expect(a.backend.calls, ['pause', 'seek 1000']);
    });

    test('the sleep timer shown is the playing device\'s, on the clock of the one that reads it', () async {
      cluster.clockOffsetMs = 7000; // the clock of the server is 7 s ahead of both
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await until(() => b.connect.devices.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the pings of the start are answered
      await startPlaying(a);
      final ends = DateTime.now().add(const Duration(minutes: 10));
      a.backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: ends)));
      await until(() => b.seen.whereType<SleepEvent>().any((e) => e.sleep.on));
      final shown = b.seen.whereType<SleepEvent>().last.sleep.endsAt!;
      expect(shown.difference(ends).inSeconds.abs(), lessThan(2));
    });
  });

  group('changing the device that plays', () {
    test('playing here takes the queue of the other device, where it stood, and that one stops', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a, queue: handover(songs: 3, index: 1, positionMs: 31000, dropped: 2));
      await until(() => b.connect.controlling);
      b.connect.playHere();
      await until(() => b.connect.playingHere, why: 'b plays');
      // A stopped and gave its queue; B took it and plays it
      expect(a.backend.calls, containsAllInOrder(['pause', 'queueExport']));
      final imported = b.backend.calls.singleWhere((c) => c.startsWith('queueImport'));
      expect(imported, startsWith('queueImport play=true '));
      expect(jsonDecode(imported.substring('queueImport play=true '.length))['positionMs'], 31000);
      expect(b.connect.dropped.value, 2, reason: 'the person is told that two songs stayed behind');
      await until(() => a.connect.controlling);
      expect(a.connect.activeDevice?.info?.name, 'Phone');
      expect(b.backend.calls, isNot(contains('pause')));
    });

    test('the device that let go drops its queue, so that it loads nothing, and its screens do not flash empty', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      await until(() => a.backend.calls.contains('clear'), why: 'a drops its queue');
      expect(a.backend.calls, containsAllInOrder(['pause', 'queueExport', 'clear']), reason: 'after its queue was handed over');
      // The player says that it is empty: the screens are not told while the other one is yet to speak
      final seen = a.states.length;
      a.backend.emit(const StateEvent(RoomSnapshot()));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(a.states.length, seen);
      // The device that plays now speaks: that is shown
      b.backend.emit(StateEvent(room()));
      b.backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 5000, durationMs: 200000)));
      await until(() => a.connect.remote != null && a.states.last.snapshot.queue.isNotEmpty, why: 'the new state is shown');
    });

    test('a device that was only waiting with a queue when it handed over drops it too, and one that had never played keeps its own', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      final c = await device('cccccccc-tablet');
      await until(() => c.connect.devices.length == 3);
      c.backend.emit(StateEvent(room(phase: 'paused')));
      await startPlaying(a);
      a.backend.emit(const PositionEvent(PlayerPosition(playing: false, positionMs: 8000, durationMs: 200000)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await until(() => b.connect.controlling);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      await until(() => a.backend.calls.contains('clear'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.backend.calls, isNot(contains('clear')), reason: 'its songs are its own: nobody took them over');
    });

    test('a device that was paused when it handed over hands over paused', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      a.backend.emit(const PositionEvent(PlayerPosition(playing: false, positionMs: 8000, durationMs: 200000)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await until(() => b.connect.controlling);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      await until(() => b.backend.calls.any((c) => c.startsWith('queueImport')));
      expect(b.backend.calls.single.startsWith('queueImport play=false '), isTrue);
    });

    test('the one that was told to let go does not take the sound back by what its player says late', () async {
      final a = await device('aaaaaaaa-phone', grace: const Duration(seconds: 2));
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      // A's player still says it plays, a moment after it was stopped
      a.backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 6000, durationMs: 200000)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cluster.active, b.id);
      expect(cluster.sent.where((s) => s.$1 == a.clientId && s.$2['t'] == 'claim').length, 1, reason: 'only the first, when it began');
    });

    test('a device whose line was down while another took the playing stops its own sound and does not take it back', () async {
      final a = await device('aaaaaaaa-phone', grace: const Duration(milliseconds: 20));
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      // A's line drops; B plays from what was kept, while A, with no line, still sounds
      cluster.drop(a.clientId);
      await until(() => b.connect.activeId == null);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      expect(a.backend.calls, isNot(contains('pause')), reason: 'it was out of reach');
      // The line of A is back: it finds another playing, and stops
      await until(() => a.connect.link == ConnectLink.online && a.connect.activeId == b.id, why: 'a is back');
      await until(() => a.backend.calls.contains('pause'), why: 'a stops its sound');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cluster.active, b.id, reason: 'and the playing stays where it moved');
      expect(cluster.sent.where((s) => s.$1 == a.clientId && s.$2['t'] == 'claim').length, 1, reason: 'only the first claim, long before');
    });

    test('a device that plays by itself while another plays takes the playing, and the other stops', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      // B's own button: sound begins here, not through the steering
      b.backend.handover = handover();
      b.backend.emit(StateEvent(room()));
      b.backend.emit(const PositionEvent(PlayerPosition(playing: true, positionMs: 100, durationMs: 200000)));
      await until(() => b.connect.playingHere, why: 'b takes it');
      await until(() => a.backend.calls.contains('pause'), why: 'a is told to stop');
      await until(() => a.connect.controlling);
    });

    test('a device that goes away leaves its last queue, which another can go on from', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a, queue: handover(songs: 3, index: 2, positionMs: 77000));
      await until(() => b.connect.controlling && b.connect.remoteQueue != null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      a.connect.dispose();
      cluster.drop(a.clientId);
      await until(() => b.connect.activeId == null, why: 'nobody plays');
      expect(b.connect.controlling, isFalse);
      b.connect.playHere();
      await until(() => b.connect.playingHere);
      final imported = b.backend.calls.singleWhere((c) => c.startsWith('queueImport'));
      expect(jsonDecode(imported.substring(imported.indexOf('{')))['index'], 2);
    });

    test('a device in a room is not offered, and does not hold the playing', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      await startPlaying(a);
      await until(() => b.connect.controlling);
      a.backend.emit(StateEvent(room(local: false)));
      await until(() => b.connect.activeId == null, why: 'a let go of the playing');
      await until(() => b.connect.devices.any((d) => d.info?.inRoom == true));
      b.connect.transferTo(a.id);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cluster.sent.where((s) => s.$2['t'] == 'transfer'), isEmpty, reason: 'a device in a room is not a place to play');
    });
  });

  group('the screens', () {
    test('a screen that listens after the backend has spoken is told what it said', () async {
      // The web backend says its first state as soon as it is listened to, which is while start() runs and before the room
      // controller listens: without this the page waits for a state for ever and shows nothing
      final backend = FakeBackend();
      final connect = ConnectController(
        inner: backend,
        syncChanges: ChangeNotifier(),
        syncKey: () => null,
        server: () async => Uri.parse('http://server'),
        serverKey: () async => 'k',
        store: _Memory({'client': 'aaaaaaaa-phone'}),
        kind: () => DeviceKind.phone,
        defaultName: () => 'Phone',
        opener: cluster.opener,
      );
      addTearDown(connect.dispose);
      await connect.start();
      backend.emit(StateEvent(room(index: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final heard = <BackendEvent>[];
      final sub = connect.events.listen(heard.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(heard.whereType<StateEvent>().map((e) => e.snapshot.index), [2]);
    });

    test('when this device stops controlling, the screens are given its own state back', () async {
      final a = await device('aaaaaaaa-phone');
      final b = await device('bbbbbbbb-tv');
      b.backend.emit(StateEvent(room(index: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await startPlaying(a);
      await until(() => b.connect.controlling);
      final during = b.states.length;
      // Its own player's news is not shown while the other one plays
      b.backend.emit(StateEvent(room(index: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(b.states.length, during);
      a.connect.dispose();
      cluster.drop(a.clientId);
      await until(() => !b.connect.controlling);
      expect(b.states.last.snapshot.index, 1, reason: 'the last thing its own player said');
    });
  });
}

/// A socket of a server that welcomes and answers pings for as long as [answers] says so.
class _QuietSocket implements RoomSocket {
  _QuietSocket(this._onMessage, this._answers);

  final void Function(String text) _onMessage;
  final bool Function() _answers;
  int? closedWith;

  @override
  void send(String text) {
    final m = jsonDecode(text) as Map<String, dynamic>;
    if (m['t'] == 'hello') {
      scheduleMicrotask(() => _onMessage(jsonEncode({'t': 'welcome', 'v': 1, 'you': 'aaaaaaaa', 'devices': <Object>[], 'active': null, 'now': 0})));
    } else if (m['t'] == 'ping' && _answers()) {
      scheduleMicrotask(() => _onMessage(jsonEncode({'t': 'pong', 'c0': m['c0'], 's1': DateTime.now().millisecondsSinceEpoch})));
    }
  }

  @override
  void close(int code, String reason) => closedWith = code;
}
