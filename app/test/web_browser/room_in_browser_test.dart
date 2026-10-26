@TestOn('browser')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/clocks.dart';
import 'package:sapoche/data/web/group_session.dart';
import 'package:sapoche/data/web/player_port.dart';
import 'package:sapoche/data/web/room_client.dart';
import 'package:sapoche/data/web/web_backend.dart';
import 'package:sapoche/data/web/wire.dart';
import 'package:sapoche/data/web/youtube_player_web.dart';
import 'package:web/web.dart' as web;

// A real browser, a real YouTube frame and a room server on this machine. Run it with
//   CHROME_EXECUTABLE=<chrome> flutter test --platform chrome test/web_browser \
//     --dart-define=SAPOCHE_SERVER=http://localhost:8799 --dart-define=SAPOCHE_KEY=<room key>
// Without SAPOCHE_SERVER it does nothing, so a plain `flutter test` stays offline.
const _server = String.fromEnvironment('SAPOCHE_SERVER');
const _key = String.fromEnvironment('SAPOCHE_KEY');
const _videoId = String.fromEnvironment('SAPOCHE_VIDEO', defaultValue: 'dQw4w9WgXcQ');

/// A player that does everything right: its position is exactly where the clock puts it once it plays. It stands for
/// a phone that is in step with the room.
class OraclePlayer extends PlayerPort {
  final _watch = Stopwatch()..start();
  var _base = 0;
  var _since = 0;
  var _playing = false;
  QueueEntry? loaded;

  int get _now => _watch.elapsedMilliseconds;

  @override
  Future<void> prepare(QueueEntry item, int seekToMs) async {
    loaded = item;
    _base = seekToMs;
    _playing = false;
  }

  @override
  void refresh(String videoId) {}

  @override
  Future<void> seekTo(int positionMs) async {
    _base = positionMs;
    _since = _now;
  }

  @override
  void play() {
    if (_playing) return;
    _playing = true;
    _since = _now;
  }

  @override
  void pause() {
    if (!_playing) return;
    _base = positionMs();
    _playing = false;
  }

  @override
  void stop() => _playing = false;

  @override
  void setSpeed(double speed) {}

  @override
  void setNext(QueueEntry? item) {}

  @override
  int positionMs() => _playing ? _base + (_now - _since) : _base;

  @override
  bool isPlaying() => _playing;
}

void main() {
  test('a browser with the real YouTube player follows a room', () async {
    final sw = Stopwatch()..start();
    final lines = <String>[];
    void note(String line) {
      lines.add('[${sw.elapsedMilliseconds}] $line');
      // ignore: avoid_print
      print('[${sw.elapsedMilliseconds}] $line');
    }

    // Where the frame goes; in the app a view of the page shows the element of the frame
    final host = web.document.createElement('div') as web.HTMLDivElement
      ..style.cssText = 'position:fixed;right:8px;bottom:8px;width:356px;height:200px;z-index:5';
    web.document.body!.append(host);

    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final code = String.fromCharCodes([
      for (var i = 0; i < 6; i++) alphabet.codeUnitAt(DateTime.now().microsecondsSinceEpoch ~/ (i + 1) % alphabet.length),
    ]);
    note('room $code on $_server');

    // The phone: in step with the room by construction, and it adds the song and presses play
    final botClock = ClockSync();
    final botPlayer = OraclePlayer();
    late final RoomClient bot;
    final botSession = GroupSession(
      player: botPlayer,
      clock: botClock,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      send: (t) => bot.send(t),
      log: (m) => note('bot: $m'),
    );
    bot = RoomClient(
      baseUrl: Uri.parse(_server),
      roomCode: code,
      clientId: 'bot-${DateTime.now().microsecondsSinceEpoch}',
      name: 'Bot',
      clock: botClock,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      key: _key,
      create: true,
      probeAuth: () async => null,
    );
    final botConnected = Completer<void>();
    bot.onMessage = (m) {
      botSession.onMessage(m);
      if (m is StateMessage && !botConnected.isCompleted) botConnected.complete();
    };
    bot.start();
    await botConnected.future.timeout(const Duration(seconds: 10));
    note('bot is in the room');
    bot.send(
      Wire.queueAdd(const TrackRef('', 'x', 'y', null, 0)),
    ); // a bad item must not break anything: the server drops it
    bot.send(Wire.queueAdd(TrackRef(_videoId, 'Test song', 'Test', null, 600000)));

    // The browser
    SharedPreferences.setMockInitialValues({'web.key': _key, 'web.server': _server});
    final prefs = await SharedPreferences.getInstance();
    final player = YoutubePlayer(host: host)
      ..onNeedsGesture = (() => note('the frame needs a tap to play'))
      ..log = ((l) => note('player: $l'));
    final backend = WebBackend(
      player: player,
      prefs: prefs,
      defaultServer: _server,
      sink: (l) => note('web: $l'),
    );
    final drifts = <int>[];
    var connected = false;
    var sawPlaying = false;
    final failures = <String>[];
    backend.events.listen((e) {
      if (e is StateEvent && e.snapshot.link == Link.connected) connected = true;
      if (e is PositionEvent) {
        if (e.position.playing) sawPlaying = true;
        final d = e.position.driftMs;
        if (d != null) drifts.add(d);
      }
      if (e is ErrorEvent) failures.add('${e.error.code}: ${e.error.message}');
    });
    await backend.join(code, 'Browser');
    await _until(() => connected, 'the browser to be connected', const Duration(seconds: 10));
    note('browser is in the room');

    bot.send(Wire.play());
    await _until(() => sawPlaying || failures.isNotEmpty, 'the browser to play', const Duration(seconds: 45));
    note('failures: $failures');
    expect(failures, isEmpty, reason: 'the frame played or failed: $failures');

    // Let it run, then read how far it was from the room
    await Future<void>.delayed(const Duration(seconds: 25));
    note('drift readings: ${drifts.length}; last 10: ${drifts.length > 10 ? drifts.sublist(drifts.length - 10) : drifts}');
    expect(sawPlaying, isTrue);
    expect(drifts, isNotEmpty);
    final tail = drifts.length > 20 ? drifts.sublist(drifts.length - 20) : drifts;
    final worst = tail.map((d) => d.abs()).reduce((a, b) => a > b ? a : b);
    note('worst drift over the last ${tail.length} readings: ${worst}ms');
    expect(worst, lessThan(1500), reason: 'the browser stayed within 1.5 s of the room');

    await backend.leave();
    bot.close();
  });
}

Future<void> _until(bool Function() ok, String what, Duration within) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
