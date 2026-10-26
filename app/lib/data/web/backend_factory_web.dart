import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

import '../backend.dart';
import 'library_disk_web.dart';
import 'library_store.dart';
import 'media_controls_web.dart';
import 'web_backend.dart';
import 'youtube_player_web.dart';

/// A browser: the room connection and the sync in Dart, the sound from the YouTube player of the page.
Future<Backend> createBackend() async {
  // A link to a room opens the app on it once, and is not asked again when the page is loaded again
  final prefs = await SharedPreferences.getInstance();
  // The key of a link (see index.html), kept for the next visits
  final sent = web.window.sessionStorage.getItem('sapoche.setupKey');
  if (sent != null && sent.trim().isNotEmpty) await prefs.setString('web.key', sent.trim());
  web.window.sessionStorage.removeItem('sapoche.setupKey');
  final invite = Uri.base.queryParameters['join']?.toUpperCase();
  if (invite != null) web.window.history.replaceState(null, '', web.window.location.pathname);
  final disk = IndexedDbDisk();
  String? stored;
  try {
    stored = await disk.read();
  } on Object catch (e) {
    // A browser that will not keep data (a private window) still plays, with a library that lasts until the page closes
    web.console.log('library: could not read the stored library: $e'.toJS);
  }
  final backend = WebBackend(
  library: LibraryStore(disk: disk, stored: stored),
  player: YoutubePlayer()..log = (line) => web.console.log('player: $line'.toJS),
  prefs: prefs,
  // The room server serves this app, so its address is where the page came from
  defaultServer: web.window.location.origin,
  region: () => PlatformDispatcher.instance.locale.countryCode ?? 'US',
  invite: invite != null && RegExp(r'^[A-Z0-9]{6}$').hasMatch(invite) ? invite : null,
  onShare: _share,
  media: BrowserMediaControls(),
  sink: (line) => web.console.log(line.toJS),
);
  // A page that goes away does not wait for the pause before a write
  web.document.addEventListener('visibilitychange', ((web.Event _) {
    if (web.document.visibilityState == 'hidden') backend.flush().ignore();
  }).toJS);
  return backend;
}

/// The share sheet where the browser has one (phones), else the clipboard.
Future<void> _share(String text) async {
  final navigator = web.window.navigator;
  if ((navigator as JSObject).has('share')) {
    await navigator.share(web.ShareData(text: text)).toDart;
  } else {
    await navigator.clipboard.writeText(text).toDart;
  }
}
