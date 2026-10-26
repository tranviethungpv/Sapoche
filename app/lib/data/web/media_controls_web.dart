import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_backend.dart';

/// The Media Session API: the media keys of a keyboard, the lock screen and notification of a phone, the controls of
/// a headset.
class BrowserMediaControls implements MediaControls {
  web.MediaSession get _session => web.window.navigator.mediaSession;

  @override
  void update({String? title, String? artist, String? artwork, required bool playing}) {
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
    void on(String action, void Function() handler) {
      try {
        _session.setActionHandler(action, ((JSObject _) => handler()).toJS);
      } on Object {
        // A browser that does not know this action leaves it out
      }
    }

    on('play', play);
    on('pause', pause);
    on('nexttrack', next);
    on('previoustrack', prev);
    try {
      _session.setActionHandler(
        'seekto',
        ((JSObject details) {
          final to = details.getProperty<JSNumber?>('seekTime'.toJS)?.toDartDouble;
          if (to != null) seek((to * 1000).round());
        }).toJS,
      );
    } on Object {
      // Not every browser has it
    }
  }
}
