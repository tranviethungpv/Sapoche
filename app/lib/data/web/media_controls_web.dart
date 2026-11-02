import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_backend.dart';

/// The Media Session API: the media keys of a keyboard, the lock screen and notification of a phone, the controls of
/// a headset.
class BrowserMediaControls implements MediaControls {
  web.MediaSession get _session => web.window.navigator.mediaSession;

  void Function()? _next;
  void Function()? _prev;
  void Function(int positionMs)? _seek;
  bool? _steering;

  @override
  void update({String? title, String? artist, String? artwork, required bool playing, bool canSteer = true}) {
    _steer(canSteer);
    if (title == null) {
      _session.metadata = null;
      _session.playbackState = 'none';
      return;
    }
    _session.metadata = web.MediaMetadata(
      web.MediaMetadataInit(
        title: title,
        artist: artist ?? '',
        artwork: [if (artwork != null) web.MediaImage(src: artwork, sizes: '544x544')].toJS,
      ),
    );
    _session.playbackState = playing ? 'playing' : 'paused';
  }

  @override
  void bind({
    required void Function() play,
    required void Function() pause,
    required void Function() next,
    required void Function() prev,
    required void Function(int positionMs) seek,
  }) {
    _next = next;
    _prev = prev;
    _seek = seek;
    _handle('play', ((JSObject _) => play()).toJS);
    _handle('pause', ((JSObject _) => pause()).toJS);
    _steering = null;
    _steer(true);
  }

  /// Skip and seek are given to the browser only while this device may move the room; without a handler its media keys
  /// and lock screen leave those buttons out.
  void _steer(bool allowed) {
    if (_steering == allowed || _next == null) return;
    _steering = allowed;
    _handle('nexttrack', allowed ? ((JSObject _) => _next!()).toJS : null);
    _handle('previoustrack', allowed ? ((JSObject _) => _prev!()).toJS : null);
    _handle(
      'seekto',
      allowed
          ? ((JSObject details) {
              final to = details.getProperty<JSNumber?>('seekTime'.toJS)?.toDartDouble;
              if (to != null) _seek!((to * 1000).round());
            }).toJS
          : null,
    );
  }

  void _handle(String action, JSFunction? handler) {
    try {
      _session.setActionHandler(action, handler);
    } on Object {
      // A browser that does not know this action leaves it out
    }
  }
}
