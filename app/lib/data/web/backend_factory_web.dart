import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

import '../backend.dart';
import 'library_disk_web.dart';
import 'library_store.dart';
import 'media_controls_web.dart';
import 'push_port_web.dart';
import 'web_backend.dart';
import 'youtube_player_web.dart';

/// A browser: the room connection and the sync in Dart, the sound from the YouTube player of the page.
Future<Backend> createBackend() async {
  // A link to a room opens the app on it once, and is not asked again when the page is loaded again
  final prefs = await SharedPreferences.getInstance();
  // The key of a link (see index.html), kept for the next visits
  try {
    final sent = web.window.sessionStorage.getItem('sapoche.setupKey');
    if (sent != null && sent.trim().isNotEmpty) await prefs.setString('web.key', sent.trim());
    web.window.sessionStorage.removeItem('sapoche.setupKey');
  } on Object {
    // A browser that keeps nothing for a page (it may refuse even to say so) still opens the app
  }
  final invite = Uri.base.queryParameters['join']?.toUpperCase();
  final fromNotice = Uri.base.queryParameters['chat'] == '1';
  // The secret of a room whose chat is end-to-end encrypted is in the link after a #: it is taken out of the address
  // at once, so that it stays out of the history
  final inviteSecret = Uri.base.fragment.split('&').where((p) => p.startsWith('k=')).map((p) => p.substring(2)).firstOrNull;
  if (invite != null) web.window.history.replaceState(null, '', web.window.location.pathname);
  final disk = IndexedDbDisk();
  String? stored;
  var keeping = true;
  try {
    // A browser that never answers (IndexedDB can hang, in a private window or in Safari) must not keep the app waiting
    stored = await disk.read().timeout(const Duration(seconds: 4));
  } on Object catch (e) {
    // The library then lasts until the page closes: it is not written over what the browser may still hold
    keeping = false;
    web.console.log('library: could not read the stored library: $e'.toJS);
  }
  final backend = WebBackend(
  library: LibraryStore(disk: keeping ? disk : null, stored: stored),
  player: YoutubePlayer()..log = (line) => web.console.log('player: $line'.toJS),
  prefs: prefs,
  // The room server serves this app, so its address is where the page came from
  defaultServer: web.window.location.origin,
  region: () => PlatformDispatcher.instance.locale.countryCode ?? 'US',
  invite: invite != null && RegExp(r'^[A-Z0-9]{6}$').hasMatch(invite) ? invite : null,
  openChat: fromNotice,
  inviteSecret: inviteSecret,
  // The service worker of the page opens the previews of notices with the secrets kept here
  secretsDisk: IndexedDbDisk(name: 'sapoche-keys', key: 'secrets'),
  onShare: _share,
  media: BrowserMediaControls(),
  push: createPushPort(),
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
