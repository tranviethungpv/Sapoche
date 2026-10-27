import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../models.dart';
import 'push_port.dart';

PushPort createPushPort() => _BrowserPush();

class _BrowserPush implements PushPort {
  _BrowserPush() {
    if (_hasApis) {
      web.window.navigator.serviceWorker.addEventListener(
        'message',
        ((web.MessageEvent event) {
          final data = event.data;
          if (!data.isA<JSObject>()) return;
          final message = data as JSObject;
          final room = message['room'];
          if ((message['type'] as JSString?)?.toDart == 'open-chat' &&
              room.isA<JSString>()) {
            _opened.add((room as JSString).toDart);
          }
        }).toJS,
      );
    }
  }

  final _opened = StreamController<String>.broadcast();

  @override
  Stream<String> get opened => _opened.stream;

  bool get _hasApis =>
      web.window.has('PushManager') &&
      web.window.has('Notification') &&
      web.window.navigator.has('serviceWorker');

  bool get _isIos =>
      RegExp('iPhone|iPad|iPod').hasMatch(web.window.navigator.userAgent) ||
      (web.window.navigator.platform == 'MacIntel' &&
          web.window.navigator.maxTouchPoints > 1);

  bool get _standalone =>
      web.window.matchMedia('(display-mode: standalone)').matches ||
      ((web.window.navigator['standalone'] as JSBoolean?)?.toDart ?? false);

  @override
  PushSupport get support {
    if (_isIos && !_standalone) return PushSupport.needsInstall;
    return _hasApis ? PushSupport.ready : PushSupport.none;
  }

  @override
  NoticePermission get permission {
    if (!_hasApis) return NoticePermission.undecided;
    return switch (web.Notification.permission) {
      'granted' => NoticePermission.granted,
      'denied' => NoticePermission.denied,
      _ => NoticePermission.undecided,
    };
  }

  /// The worker of the page, started if it was not.
  Future<web.ServiceWorkerRegistration> _worker() async {
    await web.window.navigator.serviceWorker.register('sw.js'.toJS).toDart;
    return web.window.navigator.serviceWorker.ready.toDart;
  }

  @override
  Future<Map<String, Object?>?> subscribe(String serverKey) async {
    if (support != PushSupport.ready) {
      return null;
    }
    try {
      if ((await web.Notification.requestPermission().toDart).toDart != 'granted') {
        return null;
      }
      final worker = await _worker();
      final options = web.PushSubscriptionOptionsInit(
        userVisibleOnly: true,
        applicationServerKey: base64Url
            .decode(base64Url.normalize(serverKey))
            .toJS,
      );
      web.PushSubscription sub;
      try {
        sub = await worker.pushManager.subscribe(options).toDart;
      } on Object {
        // A subscription made for another key of the server is in the way: the browser takes only one
        await (await worker.pushManager.getSubscription().toDart)
            ?.unsubscribe()
            .toDart;
        sub = await worker.pushManager.subscribe(options).toDart;
      }
      return _json(sub);
    } on Object {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>?> current() async {
    if (support != PushSupport.ready || permission != NoticePermission.granted) {
      return null;
    }
    try {
      final worker = await web.window.navigator.serviceWorker
          .getRegistration('sw.js')
          .toDart;
      final sub = await worker?.pushManager.getSubscription().toDart;
      return sub == null ? null : _json(sub);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> unsubscribe() async {
    try {
      final worker = await web.window.navigator.serviceWorker
          .getRegistration('sw.js')
          .toDart;
      await (await worker?.pushManager.getSubscription().toDart)
          ?.unsubscribe()
          .toDart;
    } on Object {
      // Nothing to let go of
    }
  }

  Map<String, Object?> _json(web.PushSubscription sub) {
    final json = sub.toJSON();
    String key(String name) => (json.keys[name] as JSString).toDart;
    return {
      'endpoint': json.endpoint,
      'keys': {'p256dh': key('p256dh'), 'auth': key('auth')},
    };
  }
}
