import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../models.dart';
import 'player_port.dart';
import 'video_frame_element.dart';

// The YouTube IFrame Player API (https://developers.google.com/youtube/iframe_api_reference) as a PlayerPort.
// What a frame cannot do, the session is told by what this leaves out: no gapless successor (setNext does nothing,
// onAdvanced never fires) and speeds only in the steps the frame knows, so drift is fixed by seeking.

@JS('YT.Player')
extension type _YtPlayer._(JSObject _) implements JSObject {
  external _YtPlayer(JSAny element, JSObject options);
  external void loadVideoById(JSObject args);
  external void playVideo();
  external void pauseVideo();
  external void stopVideo();
  external void seekTo(num seconds, bool allowSeekAhead);
  // Before a video is loaded these answer nothing at all
  external num? getCurrentTime();
  external num? getDuration();
  external int? getPlayerState();
  external void setPlaybackRate(num rate);
  external void mute();
  external void unMute();
  external void setVolume(num percent);
}

extension type _YtEvent._(JSObject _) implements JSObject {
  external JSNumber? get data;
}

/// Player states of the frame.
const _ended = 0;
const _playing = 1;
const _buffering = 3;

/// The steps of speed the frame accepts.
const _rates = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

class YoutubePlayer extends PlayerPort {
  YoutubePlayer({web.HTMLElement? host}) : host = host ?? videoFrameElement();

  /// The element the frame goes into. The app keeps it on screen (see `ui/widgets/video_frame.dart`): the player of
  /// YouTube has to be seen wherever it plays.
  final web.HTMLElement host;

  _YtPlayer? _player;
  Future<void>? _ready;
  int _state = -1;
  int _generation = 0;
  Completer<void>? _waitPlaying;
  String? _loadedVideoId;
  String? _loadingVideoId;

  /// Playing does not start without a tap of the person: set when a load found out.
  void Function()? onNeedsGesture;

  /// Where lines for the diary go.
  void Function(String line)? log;

  Future<void> _start() => _ready ??= _create();

  Future<void> _create() async {
    // The page puts the host in the document once its first frame is drawn; a frame made before that never loads
    for (var i = 0; i < 100 && !host.isConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _loadApi();
    final created = Completer<void>();
    final events = JSObject()
      ..['onReady'] = ((JSAny? _) {
        if (!created.isCompleted) created.complete();
      }).toJS
      ..['onStateChange'] = ((JSAny? e) {
        _onState((e as _YtEvent).data?.toDartInt ?? -1);
      }).toJS
      ..['onError'] = ((JSAny? e) {
        _onFrameError((e as _YtEvent).data?.toDartInt ?? 0);
      }).toJS;
    final vars = {
      'playsinline': 1,
      'controls': 0,
      'disablekb': 1,
      'rel': 0,
      'fs': 0,
      'iv_load_policy': 3,
      'origin': web.window.location.origin,
    }.jsify()!;
    final options = JSObject()
      ..['width'] = '100%'.toJS
      ..['height'] = '100%'.toJS
      ..['playerVars'] = vars
      ..['events'] = events;
    // The object has no methods until the frame says it is ready, so nobody else sees it before that
    // The frame takes the place of the element it is given, so the host keeps an element of its own to give
    final place = web.document.createElement('div');
    host.append(_fit..append(place));
    web.ResizeObserver(((JSAny a, JSAny b) => _fitFrame()).toJS).observe(host);
    _fitFrame();
    final player = _YtPlayer(place as JSObject, options);
    await created.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw LoadFailure(LoadReason.offline, 'the YouTube player did not start'),
    );
    _player = player;
  }

  /// The piece that holds the frame. The frame picks the quality of the picture by the size it is laid out at (the
  /// quality it is asked for, `setPlaybackQuality`, is not heard any more), so it is laid out as large as the quality
  /// wanted and shrunk with `transform` to fit the place the app gives it.
  final web.HTMLElement _fit = (web.document.createElement('div') as web.HTMLElement)..className = 'sapoche-fit';

  var _height = 480;

  /// A frame of 360 or less is given a picture of 480 whatever it is: that is the lowest the frame goes.
  static int _layoutHeight(int quality) => quality <= 480 ? 360 : quality;

  @override
  void setVideoHeight(int height) {
    _height = height;
    _fitFrame();
  }

  void _fitFrame() {
    final w = host.clientWidth;
    final h = host.clientHeight;
    // A place of a few pixels is where the frame hides in Audio mode: it asks for the least there is
    if (w < _smallest || h < _smallest) {
      _fit.style
        ..width = '100%'
        ..height = '100%'
        ..transform = 'none';
      return;
    }
    final layoutWidth = _layoutHeight(_height) * 16 / 9;
    final scale = w / layoutWidth;
    _fit.style
      ..width = '${layoutWidth.round()}px'
      ..height = '${(h / scale).round()}px'
      ..transform = 'scale($scale)';
  }

  /// Under this many pixels the frame is not on show.
  static const _smallest = 100;

  static Future<void> _loadApi() {
    final done = Completer<void>();
    final yt = globalContext['YT'];
    if (yt != null && (yt as JSObject).has('Player')) return Future.value();
    globalContext['onYouTubeIframeAPIReady'] = (() {
      if (!done.isCompleted) done.complete();
    }).toJS;
    final script = web.document.createElement('script') as web.HTMLScriptElement
      ..src = 'https://www.youtube.com/iframe_api'
      ..onerror = ((web.Event _) {
        if (!done.isCompleted) done.completeError(LoadFailure(LoadReason.offline, 'YouTube is out of reach'));
      }).toJS;
    web.document.head!.append(script);
    return done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw LoadFailure(LoadReason.offline, 'YouTube is out of reach'),
    );
  }

  void _onState(int state) {
    _state = state;
    if (state == _playing) {
      final waiting = _waitPlaying;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    } else if (state == _ended && _loadedVideoId != null && _waitPlaying == null) {
      // Left where it ended: the one who asked to stop there carries on from here
      if (_pauseAtEnd) {
        onPausedAtEnd?.call();
      } else {
        onEnded?.call();
      }
    }
  }

  void _onFrameError(int code) {
    log?.call('the frame reported error $code for ${_loadingVideoId ?? _loadedVideoId}');
    // 2 bad id, 5 the frame's player failed, 100 gone or private, 101 and 150 the owner does not allow embedding
    final error = switch (code) {
      100 || 101 || 150 || 2 => LoadFailure(LoadReason.unplayable, 'YouTube will not play this video here (error $code)'),
      _ => LoadFailure(LoadReason.offline, 'the YouTube player failed (error $code)'),
    };
    final waiting = _waitPlaying;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(error);
    } else {
      onError?.call(error);
    }
  }

  @override
  Future<void> prepare(QueueEntry item, int seekToMs) async {
    await _start();
    host.classList.remove('empty');
    final player = _player!;
    final generation = ++_generation;
    _loadedVideoId = null;
    _loadingVideoId = item.videoId;
    final waiting = _waitPlaying = Completer<void>();
    // Loaded muted, so that it buffers at once without waiting for a tap, then paused where it should start
    player.mute();
    player.loadVideoById({'videoId': item.videoId, 'startSeconds': seekToMs / 1000}.jsify()! as JSObject);
    try {
      await waiting.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      // A frame that never got to playing is waiting for a tap, or for the network
      if (generation == _generation) onNeedsGesture?.call();
    } finally {
      if (identical(_waitPlaying, waiting)) _waitPlaying = null;
    }
    if (generation != _generation) throw const _Superseded();
    player.pauseVideo();
    player.seekTo(seekToMs / 1000, true);
    player.unMute();
    _loadedVideoId = item.videoId;
  }

  @override
  void refresh(String videoId) {}

  @override
  Future<void> seekTo(int positionMs) async {
    final player = _player;
    if (player == null) return;
    player.seekTo(positionMs / 1000, true);
    // Back when the frame has caught up, or has taken too long to say
    final until = DateTime.now().add(const Duration(milliseconds: 1500));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final near = ((player.getCurrentTime() ?? 0) * 1000 - positionMs).abs() < 400;
      if (near && player.getPlayerState() != _buffering) return;
    }
  }

  @override
  void play() => _player?.playVideo();

  @override
  void pause() => _player?.pauseVideo();

  @override
  void stop() {
    _generation++;
    _loadedVideoId = null;
    _player?.stopVideo();
  }

  @override
  void setSpeed(double speed) {
    var nearest = _rates.first;
    for (final r in _rates) {
      if ((r - speed).abs() < (nearest - speed).abs()) nearest = r;
    }
    _player?.setPlaybackRate(nearest);
  }

  @override
  void setVolume(double level) => _player?.setVolume((level.clamp(0, 1) * 100).round());

  @override
  void pauseAtEnd(bool on) => _pauseAtEnd = on;

  var _pauseAtEnd = false;

  @override
  void setNext(QueueEntry? item) {}

  @override
  int positionMs() => ((_player?.getCurrentTime() ?? 0) * 1000).round();

  @override
  bool isPlaying() => _state == _playing;

  @override
  bool isBuffering() => _state == _buffering;

  @override
  int durationMs() => ((_player?.getDuration() ?? 0) * 1000).round();
}

/// A newer load took the place of this one; nobody waits for it any more.
class _Superseded implements Exception {
  const _Superseded();

  @override
  String toString() => 'superseded by a newer load';
}
